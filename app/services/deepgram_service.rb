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
