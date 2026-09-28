# frozen_string_literal: true

module Perf
  # Relative speed of each server (1.0 typical, 2.0 twice as slow): the geometric mean, over job
  # types run on at least two servers, of this server's time per work unit against the median.
  # Also refreshes the cold-start penalty.
  module SpeedIndex
    module_function

    def recompute!
      ratios = Hash.new { |h, k| h[k] = [] }
      PerfStat.where(n: Model::MIN_FIT_N..).group_by(&:structure_hash).each_value do |stats|
        ratios_to_median(stats).each { |backend_id, ratio| ratios[backend_id] << ratio }
      end
      Backend.agent.kept.find_each { update_backend!(it, ratios[it.id]) }
    end

    # For one job type: each server's best time per unit against the median server's.
    def ratios_to_median(stats)
      per_backend = stats.group_by(&:backend_id).transform_values { |s| s.map { it.model.per_unit_ms }.min }
      return {} if per_backend.size < 2

      median = per_backend.values.sort[per_backend.size / 2]
      return {} unless median.positive?

      per_backend.select { |_id, ms| ms.positive? }.transform_values { it / median }
    end

    def update_backend!(backend, ratios)
      speed = BackendSpeed.find_or_initialize_by(backend_id: backend.id)
      if ratios.any?
        speed.speed_index = Math.exp(ratios.sum { Math.log(it) } / ratios.size)
        speed.n_workflows = ratios.size
      end
      speed.cold_penalty_ms = cold_penalty(backend)
      speed.save!
    end

    def cold_penalty(backend)
      stats = PerfStat.where(backend_id: backend.id).where(n: Model::MIN_FIT_N..).group_by(&:structure_hash)
      gaps = stats.values.filter_map { cold_gap(it) }
      gaps.any? ? [gaps.sum / gaps.size, 0].max : nil
    end

    # How much slower the cold runs of one job type were than the warm ones.
    def cold_gap(pair)
      cold = pair.find { !it.warm }
      warm = pair.find(&:warm)
      return unless cold && warm

      units = cold.median_work_units || 1.0
      cold.model.p50(units) - warm.model.p50(units)
    end
  end
end
