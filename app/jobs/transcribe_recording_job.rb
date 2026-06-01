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
