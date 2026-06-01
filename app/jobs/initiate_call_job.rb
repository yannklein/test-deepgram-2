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
