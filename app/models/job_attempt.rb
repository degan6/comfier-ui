# One try at running a generation on one server, successful or not.
class JobAttempt < ApplicationRecord
  OUTCOMES = %w[completed failed rejected lost cancelled timeout].freeze

  belongs_to :generation
  belongs_to :backend, optional: true
  has_one :perf_sample, dependent: :nullify

  validates :outcome, inclusion: { in: OUTCOMES }

  scope :infra, -> { where(infra: true) }
  scope :failures, -> { where(outcome: %w[failed lost timeout]) }
end
