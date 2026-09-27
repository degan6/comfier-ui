# Exponentially decayed weighted regression sums for execute_ms ≈ a + b × work_units, per
# server, job type (structure_hash), and warmness.
class PerfStat < ApplicationRecord
  belongs_to :backend
  belongs_to :workflow, optional: true

  def model = Perf::Model.new(self)
end
