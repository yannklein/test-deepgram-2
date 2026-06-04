# Adding a Telephony AI Agent to a Rails App
### Twilio + Deepgram step-by-step tutorial

---

## Starting point

Your app already has:

- A `Patient` model (`name`, `phone_number`, `procedure_name`, `procedure_notes`)
- A `CallRecord` model (`call_sid`, `status`, `recording_url`, `transcript`, `summary`, `problem_reported`, `problem_description`)
- A `PatientsController` with `index`, `show`, `new`, and `create`
- All the views, including a "📞 Call Patient" button and a call history section

If you load the app right now, the "Call Patient" button crashes — it references `call_patient_path` which doesn't exist yet. The views are ready; the backend is what's missing. That's what this tutorial builds.

---

## What Twilio and Deepgram each do

**Twilio** is the phone company layer. You call its REST API and it dials the patient. When the patient picks up, Twilio needs to know what to do — it fetches a URL on your app and follows the XML instructions you return. Those instructions are called **TwiML** (Twilio Markup Language). Twilio also calls your app back at each stage of the call (recording ready, call ended, etc.). Those callbacks are called **webhooks**.

**Deepgram** is the AI voice layer. It has two features we use:
- **TTS (Text-to-Speech):** You send it a string. It returns MP3 audio. The patient hears a natural-sounding voice instead of a robot.
- **STT (Speech-to-Text):** You send it an audio file. It returns an accurate text transcript in under a second.

Twilio moves the audio. Deepgram understands it.

---

## The full call flow

Build order follows this flow exactly:

```
[1] User clicks "Call Patient"
      └─ PatientsController#call          ← Step 3
           └─ queues InitiateCallJob      ← Step 4

[2] InitiateCallJob (background)
      └─ Twilio REST API → dials patient

[3] Patient picks up
      └─ Twilio POST /twilio/twiml        ← Step 6 (TwilioController#twiml)
           └─ returns TwiML:
                <Play> GET /twilio/tts/:id ← Step 6 (TwilioController#tts)
                  └─ DeepgramService.text_to_speech → MP3  ← Step 5
                <Record action="/twilio/recording">

[4] Patient speaks, Twilio records it
      └─ Twilio POST /twilio/recording    ← Step 6 (TwilioController#recording)
           └─ queues TranscribeRecordingJob  ← Step 7

[5] TranscribeRecordingJob (background)
      └─ DeepgramService.transcribe_recording → transcript  ← Step 5
           └─ analyze + save to CallRecord
```

---

## Prerequisites

### Accounts

**Twilio** — sign up at [twilio.com](https://www.twilio.com/try-twilio). You need:
- **Account SID** — looks like `ACxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxx`
- **Auth Token** — on the same dashboard page
- A **Twilio phone number** capable of making voice calls (buy one for ~$1/month under Phone Numbers → Buy a number)

**Deepgram** — sign up at [console.deepgram.com](https://console.deepgram.com). You need:
- A **Deepgram API key** — create one under API Keys, default permissions are fine

### ngrok

Twilio is a server on the internet. When it sends you a webhook ("the patient just picked up"), it makes an HTTP POST to a URL you gave it. During development, your Rails server only listens on `localhost` — Twilio can't reach it.

ngrok fixes this by creating a public HTTPS tunnel to your local machine:

```bash
# install from ngrok.com/download, then:
ngrok http 3000
```

Copy the `https://` URL it gives you (e.g. `https://abc123.ngrok.io`). You'll need it below.

In the file `config/environments/development.rb`:

```
require "active_support/core_ext/integer/time"

Rails.application.configure do
  [...]
  config.hosts << /.*\.ngrok-free\.app/
end
```

### Environment variables

Create `.env` at the root of your project (never commit this file):

```
TWILIO_ACCOUNT_SID=ACxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxx
TWILIO_AUTH_TOKEN=your_auth_token
TWILIO_PHONE_NUMBER=+15550000000
DEEPGRAM_API_KEY=your_deepgram_api_key
BASE_URL=https://abc123.ngrok.io
```

---

## Step 1 — Install the Twilio gem

Open `Gemfile`. Add `twilio-ruby` right after the `jbuilder` line:

```ruby
gem "jbuilder"

# Twilio Ruby SDK — makes outbound phone calls and reads status callbacks
gem "twilio-ruby", "~> 7.0"
```

Run:

```bash
bundle install
```

That's the only external gem we need. All Deepgram communication is plain HTTP using Ruby's built-in `Net::HTTP` — no extra gem required.

---

## Step 2 — Add the routes

Before writing any code, define all the URLs the app will expose. Open `config/routes.rb` and replace its contents:

```ruby
Rails.application.routes.draw do
  root "patients#index"

  # Patient management + triggering calls
  resources :patients, only: [ :index, :show, :new, :create ] do
    member do
      post :call  # POST /patients/:id/call — queues InitiateCallJob
    end
  end

  # ── Twilio webhook endpoints ─────────────────────────────────────────────
  # Twilio's servers call these URLs at different moments during a call.
  # They must be publicly accessible — that's what ngrok is for.

  post "/twilio/twiml",     to: "twilio#twiml",     as: :twilio_twiml
  get  "/twilio/tts/:id",   to: "twilio#tts",        as: :twilio_tts
  post "/twilio/recording", to: "twilio#recording",  as: :twilio_recording
  post "/twilio/status",    to: "twilio#status",     as: :twilio_status

  get "up" => "rails/health#show", as: :rails_health_check
end
```

Here is what each Twilio route is for:

| Route | When Twilio calls it |
|---|---|
| `POST /twilio/twiml` | Patient picks up — we return XML instructions |
| `GET /twilio/tts/:id` | While playing audio — we stream Deepgram MP3 |
| `POST /twilio/recording` | Patient finished speaking — we start transcription |
| `POST /twilio/status` | Any call status change — we handle failures |

We use plain `post`/`get` lines instead of `resources` because these are webhooks, not a REST resource.

---

## Step 3 — Add `call` to `PatientsController`

This is the entry point — what happens when a user clicks "Call Patient".

Open `app/controllers/patients_controller.rb`. Add the `call` action between `create` and `private`:

```ruby
  # POST /patients/:id/call
  # Queues an outbound call for this patient.
  # Returns immediately — the actual Twilio API call happens in the background.
  def call
    patient = Patient.find(params[:id])
    InitiateCallJob.perform_later(patient.id)
    redirect_to patient, notice: "Call queued for #{patient.name}. Check back in a minute."
  end
```

**Why `perform_later` and not just calling Twilio here?**

Two reasons. First, calling Twilio's API takes ~1 second — using `perform_later` means the browser gets a response immediately while the job runs in the background. Second, background jobs automatically retry on failure, which you want for something as unreliable as an external phone call.

---

## Step 4 — Build `InitiateCallJob`

Create `app/jobs/initiate_call_job.rb`:

```ruby
require "twilio-ruby"

# InitiateCallJob places an outbound call to a patient using the Twilio REST API.
#
# Flow:
#   1. Create a CallRecord to track this call
#   2. Ask Twilio to call the patient's phone number
#   3. Tell Twilio: "when they pick up, fetch TwiML from /twilio/twiml"
#   4. Save Twilio's call SID on the record so we can match future callbacks
class InitiateCallJob < ApplicationJob
  queue_as :default

  def perform(patient_id)
    patient = Patient.find(patient_id)

    # Create the record BEFORE we call Twilio so we have an ID to pass
    # in the TwiML URL. Twilio needs a way to tell us "which patient is this?"
    # when it calls back — we embed the ID in the URL we give it.
    call_record = patient.call_records.create!(status: "initiated")

    client = Twilio::REST::Client.new(
      ENV.fetch("TWILIO_ACCOUNT_SID"),
      ENV.fetch("TWILIO_AUTH_TOKEN")
    )

    base_url = ENV.fetch("BASE_URL")  # e.g. https://abc123.ngrok.io

    call = client.calls.create(
      to:   patient.phone_number,
      from: ENV.fetch("TWILIO_PHONE_NUMBER"),

      # When the patient picks up, Twilio POSTs to this URL and follows
      # the TwiML instructions we return
      url: "#{base_url}/twilio/twiml?call_record_id=#{call_record.id}",

      # Twilio POSTs to this URL whenever the call status changes
      # (ringing → answered → completed, etc.)
      status_callback:        "#{base_url}/twilio/status",
      status_callback_event:  %w[initiated ringing answered completed],
      status_callback_method: "POST"
    )

    # Save Twilio's SID — we'll need it later to match the recording callback
    call_record.update!(call_sid: call.sid, status: "in_progress")

    Rails.logger.info "[InitiateCallJob] Call #{call.sid} started for patient #{patient.name}"
  end
end
```

**The ID-passing trick**

We create the `CallRecord` row before calling Twilio, then embed `call_record_id=#{call_record.id}` in the TwiML URL. When Twilio calls `/twilio/twiml`, it sends that query parameter back, so we can look up exactly which patient is on the phone.

We also save the `call.sid` that Twilio returns. Later, when Twilio sends the recording webhook, it only tells us the `CallSid` — not our internal ID. Saving `call_sid` on the record lets us do `CallRecord.find_by(call_sid: params[:CallSid])`.

---

## Step 5 — Build `DeepgramService`

Create `app/services/deepgram_service.rb`. The `app/services/` directory doesn't need any configuration — Rails autoloads everything under `app/`.

This service has two public methods. We'll use `text_to_speech` in the next step and `transcribe_recording` in Step 7.

```ruby
# DeepgramService wraps the two Deepgram API features we use:
#
#   1. TTS (Text-to-Speech): turn the bot's greeting into natural MP3 audio
#   2. STT (Speech-to-Text): turn the patient's recorded voice into text
#
# All communication is plain HTTP — no special gems needed.
require "net/http"
require "uri"
require "json"

class DeepgramService
  API_BASE = "https://api.deepgram.com/v1"

  # Convert text to MP3 audio bytes.
  # Returns raw MP3 bytes on success, raises on failure.
  #
  # voice: any Deepgram Aura model — see https://developers.deepgram.com/docs/tts-models
  def self.text_to_speech(text, voice: "aura-2-thalia-en")
    uri = URI("#{API_BASE}/speak?model=#{voice}")

    request = Net::HTTP::Post.new(uri)
    request["Authorization"] = "Token #{api_key}"
    request["Content-Type"]  = "application/json"
    # Tell Deepgram we want MP3 back — Twilio's <Play> can play MP3 directly
    request["Accept"]        = "audio/mpeg"
    request.body = JSON.generate({ text: text })

    response = Net::HTTP.start(uri.host, uri.port, use_ssl: true) do |http|
      http.request(request)
    end

    unless response.is_a?(Net::HTTPSuccess)
      raise "Deepgram TTS failed (#{response.code}): #{response.body}"
    end

    response.body  # raw MP3 bytes
  end

  # Transcribe a Twilio recording and return the transcript as a string.
  # recording_url: the RecordingUrl param Twilio sends to our webhook
  def self.transcribe_recording(recording_url)
    # Step 1: Download the audio from Twilio.
    # Twilio recording URLs require HTTP Basic Auth to download.
    audio_bytes = download_twilio_recording(recording_url)

    # Step 2: POST the audio bytes to Deepgram's pre-recorded transcription endpoint.
    # nova-3 is Deepgram's most accurate model for general speech.
    # smart_format=true adds punctuation and formats numbers automatically.
    uri = URI("#{API_BASE}/listen?model=nova-3&smart_format=true&punctuate=true")

    request = Net::HTTP::Post.new(uri)
    request["Authorization"] = "Token #{api_key}"
    request["Content-Type"]  = "audio/mpeg"
    request.body = audio_bytes

    response = Net::HTTP.start(uri.host, uri.port, use_ssl: true) do |http|
      http.request(request)
    end

    unless response.is_a?(Net::HTTPSuccess)
      raise "Deepgram STT failed (#{response.code}): #{response.body}"
    end

    result = JSON.parse(response.body)

    # Deepgram returns a deeply nested JSON object.
    # This path navigates to the main transcript string.
    result.dig("results", "channels", 0, "alternatives", 0, "transcript") || ""
  end

  # ── Private helpers ─────────────────────────────────────────────────────

  def self.download_twilio_recording(url)
    # Twilio recording URLs look like:
    #   https://api.twilio.com/2010-04-01/Accounts/ACxxx/Recordings/RExxx
    # Appending ".mp3" gives us MP3 format (no extension = WAV by default).
    uri = URI("#{url}.mp3")

    request = Net::HTTP::Get.new(uri)
    request.basic_auth(
      ENV.fetch("TWILIO_ACCOUNT_SID"),
      ENV.fetch("TWILIO_AUTH_TOKEN")
    )

    response = Net::HTTP.start(uri.host, uri.port, use_ssl: true) do |http|
      http.request(request)
    end

    # Twilio sometimes redirects to a CDN — follow it
    if response.is_a?(Net::HTTPRedirection)
      uri      = URI(response["location"])
      request  = Net::HTTP::Get.new(uri)
      response = Net::HTTP.start(uri.host, uri.port, use_ssl: true) do |http|
        http.request(request)
      end
    end

    unless response.is_a?(Net::HTTPSuccess)
      raise "Failed to download Twilio recording (#{response.code})"
    end

    response.body
  end

  def self.api_key
    ENV.fetch("DEEPGRAM_API_KEY")
  end

  private_class_method :download_twilio_recording, :api_key
end
```

**Understanding the Deepgram STT response**

Deepgram returns a nested JSON structure. The transcript lives at:

```json
{
  "results": {
    "channels": [{
      "alternatives": [{
        "transcript": "No, I have some swelling on the left side."
      }]
    }]
  }
}
```

`result.dig("results", "channels", 0, "alternatives", 0, "transcript")` navigates straight to it.

---

## Step 6 — Build `TwilioController`

Create `app/controllers/twilio_controller.rb`. This controller handles every webhook Twilio sends — four actions, each triggered at a different moment in the call:

```ruby
# TwilioController handles every HTTP request that Twilio sends to our app.
#
# Twilio's webhooks are server-to-server POST requests — they don't come
# from a browser and don't carry a CSRF token, so we skip that check here.
class TwilioController < ApplicationController
  skip_before_action :verify_authenticity_token

  # ── 1. Patient picks up ───────────────────────────────────────────────────
  #
  # Twilio fetches this URL the moment the patient answers.
  # We respond with TwiML — Twilio's XML format for controlling a call.
  # We tell Twilio: play our greeting audio, then record the patient's response.
  def twiml
    call_record = CallRecord.find(params[:call_record_id])

    tts_url      = "#{request.base_url}/twilio/tts/#{call_record.id}"
    callback_url = "#{request.base_url}/twilio/recording"

    render xml: <<~XML, status: :ok
      <?xml version="1.0" encoding="UTF-8"?>
      <Response>
        <Play>#{tts_url}</Play>
        <Record
          action="#{callback_url}"
          maxLength="60"
          timeout="5"
          playBeep="true"
          trim="trim-silence"
        />
      </Response>
    XML
  end

  # ── 2. Serve Deepgram TTS audio ───────────────────────────────────────────
  #
  # The <Play> tag above tells Twilio to fetch audio from tts_url.
  # Twilio GETs this endpoint; we call Deepgram TTS and stream the MP3 back.
  def tts
    call_record = CallRecord.find(params[:id])
    greeting    = build_greeting(call_record.patient)

    audio_bytes = DeepgramService.text_to_speech(greeting)

    # send_data streams binary data back with the right Content-Type header
    send_data audio_bytes, type: "audio/mpeg", disposition: "inline"
  rescue => e
    Rails.logger.error "[TwilioController#tts] #{e.message}"
    head :internal_server_error
  end

  # ── 3. Patient finished speaking ──────────────────────────────────────────
  #
  # Twilio POSTs here when the <Record> ends (silence timeout or hang-up).
  # Params include: CallSid, RecordingUrl, RecordingDuration
  def recording
    call_record = CallRecord.find_by(call_sid: params[:CallSid])

    if call_record.nil?
      Rails.logger.warn "[TwilioController#recording] No record for CallSid #{params[:CallSid]}"
      render xml: "<Response><Hangup/></Response>", status: :ok
      return
    end

    call_record.update!(recording_url: params[:RecordingUrl])

    # Wait 10 seconds before transcribing — gives Twilio time to finish
    # processing the recording file before we try to download it.
    TranscribeRecordingJob.set(wait: 10.seconds).perform_later(call_record.id)

    # An empty <Response> tells Twilio to hang up
    render xml: "<Response><Hangup/></Response>", status: :ok
  end

  # ── 4. Call status changed ────────────────────────────────────────────────
  #
  # Twilio fires this at every stage: initiated → ringing → in-progress → completed.
  # We use it mainly to catch failures (busy, no-answer, etc.).
  def status
    call_record = CallRecord.find_by(call_sid: params[:CallSid])

    if call_record
      mapped = case params[:CallStatus]
      when "busy", "failed", "no-answer", "canceled" then "failed"
      when "in-progress"                              then "in_progress"
      else nil
      end

      call_record.update!(status: mapped) if mapped
    end

    head :ok
  end

  private

  # Build the greeting text the bot will speak to the patient.
  # squish collapses the heredoc's newlines and extra spaces into one line.
  def build_greeting(patient)
    <<~TEXT.squish
      Hello, #{patient.name}. This is an automated follow-up call from your dental office
      regarding your recent #{patient.procedure_name}.
      Here are your aftercare instructions: #{patient.procedure_notes}.
      Is everything okay? Please leave your response after the beep.
    TEXT
  end
end
```

**Three things worth understanding here:**

**`skip_before_action :verify_authenticity_token`** — Rails protects against CSRF by checking that POST requests include a secret token it issued. Twilio's servers have no way to get that token. Skipping it for this controller is necessary. In production you'd replace this with Twilio signature verification (`Twilio::Security::RequestValidator`).

**Why a separate `/twilio/tts/:id` endpoint?** — TwiML's `<Play>` tag only accepts a URL. You can't embed raw audio in XML. So we need a route that calls Deepgram and streams the bytes back. `request.base_url` gives us the public ngrok URL, which Twilio can reach.

**Why `<Record>` and not `<Gather input="speech">`?** — `<Gather input="speech">` would have Twilio transcribe the audio for us, but then we wouldn't be using Deepgram. `<Record>` gives us the raw audio file so we can send it to Deepgram ourselves.

---

## Step 7 — Build `TranscribeRecordingJob`

Create `app/jobs/transcribe_recording_job.rb`. This job runs after the patient hangs up:

```ruby
# TranscribeRecordingJob runs after a patient's response has been recorded.
#
# Flow:
#   1. Download the recording from Twilio
#   2. Send it to Deepgram STT → get a text transcript
#   3. Scan the transcript for problem keywords
#   4. Build a summary and save everything to the CallRecord
class TranscribeRecordingJob < ApplicationJob
  queue_as :default

  def perform(call_record_id)
    call_record = CallRecord.find(call_record_id)

    Rails.logger.info "[TranscribeRecordingJob] Transcribing call #{call_record.call_sid}"

    transcript = DeepgramService.transcribe_recording(call_record.recording_url)

    Rails.logger.info "[TranscribeRecordingJob] Transcript: #{transcript.inspect}"

    problem_reported, problem_description = analyze_response(transcript)
    summary = build_summary(call_record.patient, transcript, problem_reported)

    call_record.update!(
      transcript:          transcript,
      summary:             summary,
      problem_reported:    problem_reported,
      problem_description: problem_description,
      status:              "completed"
    )

    Rails.logger.info "[TranscribeRecordingJob] Done. Problem reported: #{problem_reported}"
  rescue => e
    Rails.logger.error "[TranscribeRecordingJob] Error: #{e.message}"
    CallRecord.find(call_record_id).update!(status: "failed")
    raise  # re-raise so SolidQueue records the failure and can retry
  end

  private

  # Scan the transcript for signals that the patient has a problem.
  # Returns [problem_reported (Boolean), problem_description (String or nil)]
  #
  # This is intentionally simple — a real app might use an LLM here instead.
  def analyze_response(transcript)
    return [false, nil] if transcript.blank?

    text = transcript.downcase

    problem_keywords = %w[
      no not pain hurt hurts hurting ache aching sore
      swelling swollen bleeding bleed worse bad problem
      issue concern uncomfortable difficult trouble worried
    ]

    okay_keywords = %w[yes yeah yep fine good great okay ok wonderful perfect]

    has_problem    = problem_keywords.any? { |w| text.include?(w) }
    # Match on whole words only, to avoid "not okay" counting as "okay"
    is_clearly_okay = okay_keywords.any? { |w| text.split(/\W+/).include?(w) }

    if has_problem && !is_clearly_okay
      [true, transcript]
    else
      [false, nil]
    end
  end

  def build_summary(patient, transcript, problem_reported)
    if problem_reported
      "#{patient.name} may have a problem after their #{patient.procedure_name}. " \
        "They said: \"#{transcript}\""
    else
      "#{patient.name} is doing well after their #{patient.procedure_name}. No issues reported."
    end
  end
end
```

**Why the `rescue / raise` pattern?**

We catch the error to mark the record as `"failed"` (so the UI shows something useful), then re-raise it so SolidQueue records the failure and retries the job automatically.

---

## Step 8 — Run everything

You need three terminal tabs open simultaneously.

**Tab 1 — Rails server:**
```bash
rails server
```

**Tab 2 — SolidQueue (background jobs):**
```bash
jobs
```

Without this, `InitiateCallJob` and `TranscribeRecordingJob` will be queued but never run.

**Tab 3 — ngrok:**
```bash
ngrok http 3000
```

Make sure `BASE_URL` in your `.env` matches the `https://` URL ngrok is showing.

---

## Step 9 — Test the full flow

1. Open `http://localhost:3000`
2. Add a patient — use **your own phone number** as the patient's number
3. Open the patient detail page and click **"📞 Call Patient"**
4. Your phone rings — answer it
5. Listen to the bot read the greeting and aftercare instructions
6. After the beep, say something like: *"No, I have some swelling on the left side"*
7. Stay silent for 5 seconds — Twilio detects the pause and ends the recording
8. Reload the patient page after ~15 seconds
9. You should see the transcript, summary, and ⚠ problem flag

**Watch the logs in Tab 2:**
```
[InitiateCallJob] Call CAxxxxxxx started for patient Sarah Johnson
[TranscribeRecordingJob] Transcript: "No I have some swelling on the left side."
[TranscribeRecordingJob] Done. Problem reported: true
```

**Troubleshooting**

| Symptom | Likely cause |
|---|---|
| Phone doesn't ring | `BASE_URL` doesn't match current ngrok URL — update `.env` and restart Rails |
| Bot audio is silent | `Deepgram TTS failed` in Tab 1 logs — check `DEEPGRAM_API_KEY` |
| Transcript never appears | SolidQueue not running — start Tab 2 |
| `CallRecord` stuck at `in_progress` | Twilio couldn't reach `/twilio/recording` — ngrok may have timed out |
| `KeyError` on startup | A required env var is missing from `.env` |

---

## What you built

| File | What it does |
|---|---|
| `Gemfile` | Added `twilio-ruby` |
| `config/routes.rb` | Patient `call` route + 4 Twilio webhook routes |
| `app/controllers/patients_controller.rb` | Added `call` action — entry point for the whole flow |
| `app/jobs/initiate_call_job.rb` | Creates `CallRecord`, places the Twilio call |
| `app/services/deepgram_service.rb` | TTS (text → MP3) and STT (audio → transcript) |
| `app/controllers/twilio_controller.rb` | Handles all 4 Twilio webhook callbacks |
| `app/jobs/transcribe_recording_job.rb` | Transcribes, analyzes, saves the call outcome |
