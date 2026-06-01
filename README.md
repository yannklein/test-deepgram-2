# Adding a Telephony AI Agent to a Rails App
### Twilio + Deepgram step-by-step tutorial

---

## Starting point

Your app already has:

- A `Patient` model (`name`, `phone_number`, `procedure_name`, `procedure_notes`)
- A `CallRecord` model (`call_sid`, `status`, `recording_url`, `transcript`, `summary`, `problem_reported`, `problem_description`)
- A `PatientsController` with `index`, `show`, `new`, and `create`
- All the views, including a "📞 Call Patient" button and a call history section

If you load the app right now, you'll notice the "Call Patient" button crashes — it references `call_patient_path` which doesn't exist yet. The views are ready; it's the backend that's missing. That's exactly what this tutorial builds.

By the end, this will be the full call flow:

```
User clicks "Call Patient"
  └─ PatientsController#call
       └─ queues InitiateCallJob (background)
            └─ Twilio REST API → dials patient's phone
                   │
           patient picks up
                   │
           Twilio POST /twilio/twiml
             └─ TwilioController#twiml
                  └─ returns TwiML:
                       <Play> GET /twilio/tts/:id
                         └─ DeepgramService.text_to_speech → MP3 audio
                       <Record action="/twilio/recording">
                   │
           patient speaks (Twilio records it)
                   │
           Twilio POST /twilio/recording
             └─ TwilioController#recording
                  └─ saves RecordingUrl
                       └─ queues TranscribeRecordingJob (10s delay)
                            └─ DeepgramService.transcribe_recording
                                 └─ analyze + save to CallRecord
```

---

## Prerequisites

### 1. Twilio account

Sign up at [twilio.com](https://www.twilio.com/try-twilio). You need:

- Your **Account SID** — looks like `ACxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxx`
- Your **Auth Token** — on the same dashboard page
- A **Twilio phone number** capable of making voice calls (buy one for ~$1/month in the Twilio console under Phone Numbers → Manage → Buy a number)

### 2. Deepgram account

Sign up at [console.deepgram.com](https://console.deepgram.com). You need:

- A **Deepgram API key** — create one under API Keys, default permissions are fine

### 3. ngrok

Twilio is a server on the internet. When it wants to tell your app "the patient just picked up", it makes an HTTP POST to a URL you give it. During development, your Rails server only listens on `localhost` — Twilio can't reach it.

ngrok fixes this by creating a public HTTPS tunnel to your local machine.

Install it from [ngrok.com/download](https://ngrok.com/download), then run:

```bash
ngrok http 3000
```

Copy the `https://` URL it gives you (e.g. `https://abc123.ngrok.io`). You'll need it in the next step.

### 4. Environment variables

Create a `.env` file at the root of your project (never commit this):

```bash
TWILIO_ACCOUNT_SID=ACxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxx
TWILIO_AUTH_TOKEN=your_auth_token
TWILIO_PHONE_NUMBER=+15550000000
DEEPGRAM_API_KEY=your_deepgram_api_key
BASE_URL=https://abc123.ngrok.io
```

---

## Step 1 — Install the Twilio gem

Open `Gemfile`. Find the `jbuilder` line and add `twilio-ruby` right after it:

```ruby
gem "jbuilder"

# Twilio Ruby SDK — makes outbound phone calls and reads status callbacks
gem "twilio-ruby", "~> 7.0"
```

Then install it:

```bash
bundle install
```

We only need one external gem. All Deepgram communication is plain HTTP using Ruby's built-in `Net::HTTP` — no extra gem required.

---

## Step 2 — Add the routes

Before writing any controller code, map out all the URLs the app will use. Open `config/routes.rb` and replace its contents entirely:

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
  # These are called by Twilio's servers, not by a browser.
  # They must be publicly accessible (use ngrok in development).

  # Twilio calls this when patient picks up → we return TwiML instructions
  post "/twilio/twiml",     to: "twilio#twiml",     as: :twilio_twiml

  # We serve Deepgram TTS audio from here — Twilio's <Play> fetches it
  get  "/twilio/tts/:id",   to: "twilio#tts",        as: :twilio_tts

  # Twilio calls this when the patient finishes recording their response
  post "/twilio/recording", to: "twilio#recording",  as: :twilio_recording

  # Twilio calls this when call status changes (ringing, failed, etc.)
  post "/twilio/status",    to: "twilio#status",     as: :twilio_status

  get "up" => "rails/health#show", as: :rails_health_check
end
```

**Why these four Twilio routes?**

Twilio communicates with your app by making HTTP requests at specific moments during a call. These are called webhooks — Twilio POSTs to a URL, and you respond with instructions. The four routes map to the four moments we care about:

| Route | When Twilio calls it | What we return |
|---|---|---|
| `POST /twilio/twiml` | Patient picks up | TwiML XML (play audio + record) |
| `GET /twilio/tts/:id` | While executing the TwiML `<Play>` tag | MP3 audio bytes |
| `POST /twilio/recording` | Patient finishes speaking | `<Hangup/>` + queue transcription |
| `POST /twilio/status` | Call status changes at any point | `200 OK` (we just log it) |

**Why plain routes instead of `resources`?**
Twilio's callbacks don't follow REST conventions — there's no concept of creating or updating a resource. Plain `post`/`get` lines make the URL-to-action mapping obvious at a glance.

Verify the routes loaded correctly:

```bash
bin/rails routes | grep -E "patients|twilio"
```

You should see `call_patient`, `twilio_twiml`, `twilio_tts`, `twilio_recording`, and `twilio_status`.

---

## Step 3 — Build the Deepgram service

Create a new file `app/services/deepgram_service.rb`. The `app/services/` directory doesn't need any special configuration — Rails (via Zeitwerk) autoloads everything under `app/`.

```ruby
# DeepgramService wraps the two Deepgram API features we use:
#
#   1. TTS (Text-to-Speech): We send a string like "Hello, Sarah."
#      Deepgram returns MP3 audio bytes. We serve those bytes to Twilio's
#      <Play> tag so the patient hears a natural-sounding voice.
#
#   2. STT (Speech-to-Text): We send the patient's recorded audio.
#      Deepgram returns a text transcript. We analyze that text to decide
#      whether the patient reported a problem.
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

  # Transcribe a Twilio recording and return the text.
  # recording_url: the RecordingUrl param Twilio sends to our webhook
  def self.transcribe_recording(recording_url)
    # Step 1: Download the audio from Twilio.
    # Twilio requires HTTP Basic Auth — the recording URL alone won't work.
    audio_bytes = download_twilio_recording(recording_url)

    # Step 2: POST the audio bytes to Deepgram's pre-recorded transcription endpoint.
    # nova-3 is Deepgram's most accurate model for general speech.
    # smart_format=true adds punctuation and formats numbers/dates automatically.
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

  # ── Private helpers ────────────────────────────────────────────────────────

  def self.download_twilio_recording(url)
    # Twilio recording URLs look like:
    #   https://api.twilio.com/2010-04-01/Accounts/ACxxx/Recordings/RExxx
    # Appending ".mp3" gives us MP3 format (the default with no extension is WAV).
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

**Understanding the Deepgram TTS request**

```
POST https://api.deepgram.com/v1/speak?model=aura-2-thalia-en
Authorization: Token YOUR_KEY
Content-Type: application/json
Accept: audio/mpeg

{"text": "Hello, Sarah. This is a follow-up from your dental office..."}
```

The response body is raw MP3 audio. We'll serve those bytes directly to Twilio.

**Understanding the Deepgram STT request**

```
POST https://api.deepgram.com/v1/listen?model=nova-3&smart_format=true
Authorization: Token YOUR_KEY
Content-Type: audio/mpeg

[raw audio bytes]
```

The response is JSON. The transcript is nested at:
`results → channels[0] → alternatives[0] → transcript`

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
#
# Why a background job instead of calling Twilio from the controller?
# The Twilio API call takes ~1 second. We don't want the user's browser
# to wait for that — queue it and return immediately.
class InitiateCallJob < ApplicationJob
  queue_as :default

  def perform(patient_id)
    patient = Patient.find(patient_id)

    # Create the record BEFORE we call Twilio so we have an ID to pass
    # in the TwiML URL. Twilio needs a way to ask us "which patient is this?"
    call_record = patient.call_records.create!(status: "initiated")

    client = Twilio::REST::Client.new(
      ENV.fetch("TWILIO_ACCOUNT_SID"),
      ENV.fetch("TWILIO_AUTH_TOKEN")
    )

    base_url = ENV.fetch("BASE_URL")  # e.g. https://abc123.ngrok.io

    call = client.calls.create(
      to:   patient.phone_number,
      from: ENV.fetch("TWILIO_PHONE_NUMBER"),

      # When the patient picks up, Twilio fetches this URL and follows the
      # TwiML instructions we return (play audio, record response, etc.)
      url: "#{base_url}/twilio/twiml?call_record_id=#{call_record.id}",

      # Twilio will POST to this URL whenever the call status changes
      # (ringing → answered → completed, etc.) so we can update our record
      status_callback:        "#{base_url}/twilio/status",
      status_callback_event:  %w[initiated ringing answered completed],
      status_callback_method: "POST"
    )

    # Save Twilio's SID — we'll need it to match recording/status callbacks
    call_record.update!(call_sid: call.sid, status: "in_progress")

    Rails.logger.info "[InitiateCallJob] Call #{call.sid} started for patient #{patient.name}"
  end
end
```

**The ID-passing trick**

Notice how we create the `CallRecord` before calling Twilio, then pass `call_record_id=#{call_record.id}` in the TwiML URL. This is how Twilio knows which patient just answered — it sends that parameter back to us in the POST to `/twilio/twiml`.

We also get `call.sid` from Twilio's response and save it on the record. Later, when Twilio sends the recording, it only tells us the `CallSid`. We need `call_sid` in the database to look up the right `CallRecord`.

---

## Step 5 — Build `TranscribeRecordingJob`

Create `app/jobs/transcribe_recording_job.rb`:

```ruby
# TranscribeRecordingJob runs after a patient's response has been recorded.
#
# Flow:
#   1. Download the recording from Twilio
#   2. Send it to Deepgram STT → get a text transcript
#   3. Scan the transcript for problem keywords
#   4. Build a summary and save everything to the CallRecord
#
# Why a background job? Because downloading and transcribing audio can take
# several seconds. We also add a 10-second wait before starting to give
# Twilio time to finish processing the recording before we try to fetch it.
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
    raise  # re-raise so SolidQueue can retry the job
  end

  private

  # Scan the transcript for signals that the patient has a problem.
  # Returns [problem_reported (Boolean), problem_description (String or nil)]
  #
  # This is intentionally simple — a real app might use an LLM for this.
  # The key insight: if someone says "no pain" we don't want to flag it as
  # a problem, so we require at least one problem keyword WITHOUT a clear
  # affirmative (yes/fine/okay/good) at the start.
  def analyze_response(transcript)
    return [false, nil] if transcript.blank?

    text = transcript.downcase

    problem_keywords = %w[
      no not pain hurt hurts hurting ache aching sore
      swelling swollen bleeding bleed worse bad problem
      issue concern uncomfortable difficult trouble worried
    ]

    # Words that indicate the patient is doing fine
    okay_keywords = %w[yes yeah yep fine good great okay ok wonderful perfect]

    has_problem = problem_keywords.any? { |w| text.include?(w) }

    # "okay" at word boundary, to avoid matching "not okay"
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

We catch the error to mark the record as `"failed"` (so the UI shows something useful), then re-raise it so SolidQueue records the failure and can retry the job automatically.

---

## Step 6 — Build `TwilioController`

Create `app/controllers/twilio_controller.rb`:

```ruby
# TwilioController handles every HTTP request that Twilio sends to our app.
#
# Twilio's webhooks are server-to-server POST requests, not browser form
# submissions — they don't carry a CSRF token, so we skip that check here.
#
# The three callbacks we care about:
#
#   POST /twilio/twiml     — patient picked up; return XML instructions
#   POST /twilio/recording — patient finished speaking; start transcription
#   POST /twilio/status    — call status changed; update our record
#
# We also serve TTS audio on:
#   GET  /twilio/tts/:id   — generate & stream MP3 from Deepgram TTS
#
class TwilioController < ApplicationController
  skip_before_action :verify_authenticity_token

  # ── 1. Patient picks up ───────────────────────────────────────────────────
  #
  # Twilio fetches this URL as soon as the patient answers.
  # We respond with TwiML — Twilio's XML format for controlling a call.
  # We tell Twilio to: play our greeting (via Deepgram TTS), then record
  # the patient's response for up to 60 seconds.
  def twiml
    call_record = CallRecord.find(params[:call_record_id])

    # The TTS audio lives at a separate endpoint so we can stream it cleanly
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
  # Twilio's <Play> fetches audio from this URL.
  # We call Deepgram's TTS API and stream the MP3 bytes back.
  # Twilio plays the audio to the patient in real time.
  def tts
    call_record = CallRecord.find(params[:id])
    greeting    = build_greeting(call_record.patient)

    audio_bytes = DeepgramService.text_to_speech(greeting)

    # send_data streams binary data back to the caller (Twilio) as MP3
    send_data audio_bytes, type: "audio/mpeg", disposition: "inline"
  rescue => e
    Rails.logger.error "[TwilioController#tts] #{e.message}"
    head :internal_server_error
  end

  # ── 3. Patient finished speaking ──────────────────────────────────────────
  #
  # Twilio POSTs here when the <Record> completes (patient paused or hung up).
  # Params include: CallSid, RecordingUrl, RecordingDuration
  #
  # We save the recording URL and queue a background job to transcribe it.
  # We can't transcribe synchronously here — downloading audio takes time
  # and Twilio expects a response in under 15 seconds.
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
    # A production app would use Twilio's recordingStatusCallback instead.
    TranscribeRecordingJob.set(wait: 10.seconds).perform_later(call_record.id)

    # Empty response tells Twilio to hang up
    render xml: "<Response><Hangup/></Response>", status: :ok
  end

  # ── 4. Call status changed ────────────────────────────────────────────────
  #
  # Twilio fires this whenever the call moves through its lifecycle.
  # We use it to mark calls as "failed" if the patient doesn't pick up.
  def status
    call_record = CallRecord.find_by(call_sid: params[:CallSid])

    if call_record
      mapped = case params[:CallStatus]
      when "busy", "failed", "no-answer", "canceled" then "failed"
      when "in-progress"                              then "in_progress"
      else nil  # ignore other statuses — recording callback handles completion
      end

      call_record.update!(status: mapped) if mapped
    end

    head :ok
  end

  private

  # Build the greeting text the bot will speak to the patient.
  # squish removes newlines and extra spaces from the heredoc.
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

**Why `skip_before_action :verify_authenticity_token`?**

Rails protects against CSRF attacks by checking that POST requests include a secret token it issued. Twilio's servers have no way to get that token — they're not browsers that visited your app first. Skipping the check for this controller is correct and necessary.

> In production, replace this with proper Twilio signature verification using `twilio-ruby`'s `Twilio::Security::RequestValidator`. It checks a signature Twilio signs every request with, which is more secure than simply skipping the check.

**Understanding `<Record>` vs. other approaches**

We use `<Record>` to capture the patient's full response as audio, then transcribe it ourselves with Deepgram. The alternative — `<Gather input="speech">` — would have Twilio do the transcription for us, but then we wouldn't be using Deepgram. `<Record>` gives us the audio file; we control what happens to it.

**Why a separate `/twilio/tts/:id` endpoint?**

Twilio's `<Play>` tag accepts a URL and fetches audio from it via HTTP. We can't embed audio bytes directly in TwiML XML. So we need a dedicated endpoint that calls Deepgram TTS and streams the MP3 back. `request.base_url` gives us the public ngrok URL, so Twilio can reach it.

---

## Step 7 — Add `call` to `PatientsController`

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

Your controller should now look like this:

```ruby
class PatientsController < ApplicationController
  def index
    @patients = Patient.includes(:call_records).order(created_at: :desc)
  end

  def show
    @patient      = Patient.find(params[:id])
    @call_records = @patient.call_records.recent
  end

  def new
    @patient = Patient.new
  end

  def create
    @patient = Patient.new(patient_params)

    if @patient.save
      redirect_to @patient, notice: "Patient added."
    else
      render :new, status: :unprocessable_entity
    end
  end

  # POST /patients/:id/call
  # Queues an outbound call for this patient.
  # Returns immediately — the actual Twilio API call happens in the background.
  def call
    patient = Patient.find(params[:id])
    InitiateCallJob.perform_later(patient.id)
    redirect_to patient, notice: "Call queued for #{patient.name}. Check back in a minute."
  end

  private

  def patient_params
    params.require(:patient).permit(:name, :phone_number, :procedure_name, :procedure_notes)
  end
end
```

**Why `perform_later` and not `perform_now`?**

`perform_later` queues the job in SolidQueue and returns immediately, so the browser gets a response in milliseconds. If you used `perform_now`, the user's browser would hang for 1–2 seconds while we wait for Twilio's API to respond. For a network call, always use a background job.

---

## Step 8 — Run everything

You need three terminal tabs running simultaneously.

**Tab 1 — Rails server:**
```bash
bin/rails server
```

**Tab 2 — SolidQueue (background jobs):**
```bash
bin/jobs
```
Without this, `InitiateCallJob` and `TranscribeRecordingJob` will be queued but never executed.

**Tab 3 — ngrok:**
```bash
ngrok http 3000
```
Make sure `BASE_URL` in your `.env` matches the `https://` URL ngrok shows.

---

## Step 9 — Test the full flow

1. Open `http://localhost:3000`
2. Add a patient — use **your own phone number** as the patient
3. Open the patient's detail page and click **"📞 Call Patient"**
4. You should see "Call queued for…" and a `CallRecord` with status `initiated`
5. **Your phone rings** — answer it
6. Listen to the bot read the greeting and aftercare instructions
7. After the beep, say something like: *"No, I have some swelling on the left side"*
8. Stay silent for 5 seconds — Twilio detects the silence and ends the recording
9. Reload the patient page after about 15 seconds
10. You should see the call status change to `completed`, with a transcript, summary, and the ⚠ problem flag set

**Checking logs**

Watch Tab 2 (SolidQueue) for log lines from the jobs:

```
[InitiateCallJob] Call CAxxxxxxx started for patient Sarah Johnson
[TranscribeRecordingJob] Transcript: "No I have some swelling on the left side."
[TranscribeRecordingJob] Done. Problem reported: true
```

**Troubleshooting**

| Symptom | Likely cause |
|---|---|
| Phone doesn't ring | `BASE_URL` in `.env` doesn't match current ngrok URL — restart ngrok and update the value |
| Bot voice is silent / Twilio error | Check Tab 1 for a `Deepgram TTS failed` error — verify your `DEEPGRAM_API_KEY` |
| Transcript never appears | Job didn't run — make sure Tab 2 (SolidQueue) is running |
| `CallRecord` stuck at `in_progress` | Twilio couldn't reach `/twilio/recording` — ngrok may have expired |
| `ENV::KeyError` on startup | A required env var is missing from `.env` |

---

## What you built

| File | What it does |
|---|---|
| `Gemfile` | Added `twilio-ruby` SDK |
| `config/routes.rb` | Added patient `call` action + 4 Twilio webhook routes |
| `app/services/deepgram_service.rb` | TTS (text → MP3) and STT (audio → transcript) via Deepgram API |
| `app/jobs/initiate_call_job.rb` | Places the Twilio call, creates + tracks the `CallRecord` |
| `app/jobs/transcribe_recording_job.rb` | Downloads recording, transcribes with Deepgram, analyzes, saves |
| `app/controllers/twilio_controller.rb` | Handles all 4 Twilio webhook callbacks |
| `app/controllers/patients_controller.rb` | Added the `call` action that triggers everything |
