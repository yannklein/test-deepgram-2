class CallRecord < ApplicationRecord
  belongs_to :patient

  STATUSES = %w[pending initiated in_progress completed failed].freeze

  validates :status, inclusion: { in: STATUSES }

  scope :recent, -> { order(created_at: :desc) }
  scope :with_problems, -> { where(problem_reported: true) }

  def completed?
    status == "completed"
  end

  def in_progress?
    %w[initiated in_progress].include?(status)
  end
end
