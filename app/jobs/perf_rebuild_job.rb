# frozen_string_literal: true

# Nightly: drop samples older than 90 days and rebuild every PerfStat from what's left, so the
# decayed sums can't drift from the samples.
class PerfRebuildJob < ApplicationJob
  RETENTION = 90.days

  queue_as :default

  def perform
    PerfSample.where(completed_at: ...RETENTION.ago).delete_all
    PerfStat.transaction do
      output_bytes = PerfStat.pluck(:backend_id, :structure_hash, :warm, :output_bytes_ewma)
                             .to_h { |b, s, w, o| [[b, s, w], o] }
      PerfStat.delete_all
      PerfSample.where.not(structure_hash: nil).order(:completed_at).find_each { add(it, output_bytes) }
    end
  end

  private

  def add(sample, output_bytes)
    key = [sample.backend_id, sample.structure_hash, sample.warm]
    @stats ||= {}
    stat = @stats[key] ||= PerfStat.new(backend_id: sample.backend_id, structure_hash: sample.structure_hash,
                                        warm: sample.warm, workflow_id: sample.workflow_id,
                                        output_bytes_ewma: output_bytes[key])
    weight = sample.cached_ratio > 0.5 ? Perf::Recorder::CACHED_WEIGHT : 1.0
    stat.model.add!(sample.work_units, sample.execute_ms, weight:)
    stat.save!
  end
end
