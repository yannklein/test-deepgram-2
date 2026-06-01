class CreateCallRecords < ActiveRecord::Migration[8.1]
  def change
    create_table :call_records do |t|
      t.references :patient, null: false, foreign_key: true

      # Twilio assigns a unique SID to every call — we store it so we can
      # match Twilio's callbacks (recording ready, status changes) back to
      # the right row in our database.
      t.string :call_sid

      # Tracks where we are in the call lifecycle:
      # pending → initiated → in_progress → completed (or failed)
      t.string :status, null: false, default: "pending"

      # The URL of the audio recording Twilio made of the patient's response.
      # We'll download this and send it to Deepgram for transcription.
      t.string :recording_url

      # What the patient actually said, as transcribed by Deepgram STT
      t.text :transcript

      # A short human-readable summary we generate after analyzing the transcript
      t.text :summary

      # Did the patient indicate something is wrong?
      t.boolean :problem_reported, null: false, default: false

      # If problem_reported is true, this holds what they described
      t.text :problem_description

      t.timestamps
    end
  end
end
