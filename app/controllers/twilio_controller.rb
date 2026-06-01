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

  # ── 1. Patient picks up ────────────────────────────────────────────────────
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
