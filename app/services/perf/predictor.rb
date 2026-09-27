# frozen_string_literal: true

module Perf
  # Predicts how long a job takes on a server. Falls back through five sources, each less certain:
  #   1. this server, this job type, same warmness (high with 10+ samples, else medium)
  #   2. this server, this job type, other warmness adjusted by the cold penalty (medium)
  #   3. other servers' fit for this job type, scaled by relative speed (medium)
  #   4. this server's typical time per work unit across job types (low)
  #   5. a default of DEFAULT_MS_PER_UNIT scaled by speed (low)
  class Predictor
    DEFAULT_EXECUTE_MS = 60_000
    DEFAULT_MS_PER_UNIT = 2_000.0
    Prediction = Data.define(:execute_ms, :p90_ms, :total_ms, :confidence, :source, :warm)

    def self.predict(generation, backend, warm: nil) = new(generation, backend, warm:).predict

    def initialize(generation, backend, warm: nil)
      @generation = generation
      @backend = backend
      @units = generation.work_units || Agent::WorkUnits.compute(generation)
      @structure = generation.structure_hash || generation.workflow&.structure_hash
      @warm = warm.nil? ? Agent::Warmth.warm_for?(backend, generation.model_set_hash) : warm
    end

    def predict
      execute, p90, confidence, source = execute_estimate
      total = overhead_ms + execute
      Prediction.new(execute_ms: execute.round, p90_ms: (overhead_ms + p90).round, total_ms: total.round,
                     confidence:, source:, warm: @warm)
    end

    private

    def execute_estimate
      same_server || other_warmness || other_servers || server_typical || default_estimate
    end

    def stat(backend_id, warm) = PerfStat.find_by(backend_id:, structure_hash: @structure, warm:)

    def same_server
      found = stat(@backend.id, @warm)
      return unless found && found.n >= Model::MIN_FIT_N

      model = found.model
      [model.p50(@units), model.p90(@units), found.n >= 10 ? 'high' : 'medium', 1]
    end

    def other_warmness
      found = stat(@backend.id, !@warm)
      return unless found && found.n >= Model::MIN_FIT_N

      penalty = @backend.backend_speed&.cold_penalty_ms.to_f
      shift = @warm ? -penalty : penalty
      model = found.model
      [[model.p50(@units) + shift, 0].max, model.p90(@units) + shift, 'medium', 2]
    end

    def other_servers
      stats = PerfStat.where(structure_hash: @structure, warm: @warm).where.not(backend_id: @backend.id)
                      .where(n: Model::MIN_FIT_N..).includes(backend: :backend_speed).to_a
      return if stats.empty?

      speed = @backend.speed_index
      [median(normalized(stats, :p50)) * speed, median(normalized(stats, :p90)) * speed, 'medium', 3]
    end

    # Each server's estimate as if it ran at typical speed.
    def normalized(stats, percentile)
      stats.map { it.model.public_send(percentile, @units) / it.backend.speed_index }
    end

    def server_typical
      stats = PerfStat.where(backend_id: @backend.id).where(n: Model::MIN_FIT_N..).to_a
      return if stats.empty?

      per_unit = median(stats.map { it.model.per_unit_ms })
      estimate = per_unit * @units
      [estimate, estimate * 1.5, 'low', 4]
    end

    def default_estimate
      estimate = @units.to_f.positive? ? DEFAULT_MS_PER_UNIT * @units * @backend.speed_index : DEFAULT_EXECUTE_MS
      estimate = estimate.clamp(5_000, 3_600_000)
      [estimate, estimate * 2, 'low', 5]
    end

    def overhead_ms
      @overhead_ms ||= begin
        input_bytes = @generation.generation_inputs.sum(:bytes)
        output_bytes = PerfStat.where(backend_id: @backend.id,
                                      structure_hash: @structure).maximum(:output_bytes_ewma).to_i
        Transfers.estimate_ms(@backend, 'dispatch') + Transfers.estimate_ms(@backend, 'input', bytes: input_bytes) +
          Transfers.estimate_ms(@backend, 'output', bytes: output_bytes)
      end
    end

    def median(values)
      sorted = values.sort
      mid = sorted.size / 2
      sorted.size.odd? ? sorted[mid] : (sorted[mid - 1] + sorted[mid]) / 2.0
    end
  end
end
