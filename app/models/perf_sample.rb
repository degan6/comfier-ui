# Timings from one completed attempt, the raw material for predictions.
class PerfSample < ApplicationRecord
  belongs_to :job_attempt, optional: true
  belongs_to :backend
  belongs_to :workflow, optional: true
end
