# frozen_string_literal: true

module Perf
  # Turns a completed attempt's timings into a PerfSample, updates the regression for its job
  # type, the transfer EWMAs, and the prediction log.
  class Recorder
    CACHED_WEIGHT = 0.25
    OUTLIER_WEIGHT = 0.1

    def self.record!(generation, backend, attempt, timings) = new(generation, backend, attempt, timings).record!

    def initialize(generation, backend, attempt, timings)
      @generation = generation
      @backend = backend
      @attempt = attempt
      @timings = (timings || {}).transform_keys(&:to_s)
    end

    def record!
      return if execute_ms <= 0 || @generation.structure_hash.blank?

      sample = write_sample!
      update_stat!(sample)
      update_transfers!
      log_prediction!
      sample
    end

    private

    def execute_ms = @timings['execute_ms'].to_i
    def units = (@generation.work_units || 1.0).to_f
    def warm = @attempt&.warm || false

    def cached_ratio
      total = @timings['nodes_total'].to_i
      total.positive? ? @timings['nodes_cached'].to_f / total : 0.0
    end

    def dispatch_ms
      return unless @generation.dispatched_at && @generation.accepted_at

      ((@generation.accepted_at - @generation.dispatched_at) * 1000).round
    end

    def write_sample!
      PerfSample.create!(
        job_attempt: @attempt, backend: @backend, workflow_id: @generation.workflow_id,
        structure_hash: @generation.structure_hash, warm:, work_units: units, cached_ratio:,
        dispatch_ms:, inputs_ms: @timings['inputs_ms'], local_queue_ms: @timings['local_queue_ms'],
        execute_ms:, upload_ms: @timings['upload_ms'], input_bytes: @timings['input_bytes'],
        output_bytes: @timings['output_bytes'], completed_at: Time.current
      )
    end

    def update_stat!(sample)
      stat = PerfStat.find_or_initialize_by(backend_id: @backend.id, structure_hash: sample.structure_hash, warm:)
      stat.workflow_id ||= @generation.workflow_id
      model = stat.model
      model.add!(units, execute_ms, weight: weight(model, stat))
      stat.output_bytes_ewma = Transfers.blend(stat.output_bytes_ewma, sample.output_bytes) if sample.output_bytes
      stat.save!
    end

    def weight(model, stat)
      return CACHED_WEIGHT if cached_ratio > 0.5
      return 1.0 if stat.n < 5

      predicted = model.p50(units)
      return 1.0 if predicted <= 0

      ratio = execute_ms / predicted
      ratio > 5 || ratio < 0.2 ? OUTLIER_WEIGHT : 1.0
    end

    def update_transfers!
      Transfers.observe!(@backend, 'input', bytes: @timings['input_bytes'].to_i, ms: @timings['inputs_ms'].to_i)
      Transfers.observe!(@backend, 'output', bytes: @timings['output_bytes'].to_i, ms: @timings['upload_ms'].to_i)
      Transfers.observe!(@backend, 'dispatch', bytes: 0, ms: dispatch_ms.to_i)
    end

    def log_prediction!
      started = @generation.dispatched_at || @generation.queued_at
      actual = started ? ((Time.current - started) * 1000).round : nil
      PredictionLog.create!(generation: @generation, backend: @backend, structure_hash: @generation.structure_hash,
                            predicted_total_ms: @generation.predicted_total_ms, actual_total_ms: actual,
                            confidence: @generation.prediction_confidence, source: @generation.prediction_source)
    end
  end
end
