class Patient < ApplicationRecord
  has_many :call_records, dependent: :destroy

  validates :name, :phone_number, :procedure_name, presence: true

  # Strip whitespace from phone number before saving.
  # Twilio requires E.164 format: +12125551234
  before_validation { self.phone_number = phone_number&.strip }

  def latest_call
    call_records.order(created_at: :desc).first
  end
end
