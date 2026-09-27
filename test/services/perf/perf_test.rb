# frozen_string_literal: true

require 'test_helper'

module Perf
  class PerfTest < ActiveSupport::TestCase
    setup do
      @alice = users(:alice)
      @workflow = workflows(:sd_image)
      @backend = create_agent_backend!(owner: @alice)
    end

    def stat(backend = @backend, warm: false, structure_hash: 'sd15')
      PerfStat.find_or_initialize_by(backend_id: backend.id, structure_hash:, warm:)
    end

    def fit(points, backend = @backend, **)
      record = stat(backend, **)
      points.each { |x, y| record.model.add!(x, y) }
      record.save!
      record
    end

    def generation(**attrs)
      Generation.create!({ user: @alice, workflow: @workflow, prompt: 'x', kind: :image, status: :queued,
                           agent_state: 'queued', structure_hash: 'sd15', work_units: 10 }.merge(attrs))
    end

    test 'the regression recovers a line' do
      model = fit([[1, 3_000], [5, 11_000], [10, 21_000], [20, 41_000]]).model
      a, b = model.coefficients

      assert_in_delta 1_000, a, 1
      assert_in_delta 2_000, b, 1
      assert_in_delta 31_000, model.p50(15), 5
    end

    test 'with fewer than three samples time is proportional to work units' do
      a, b = fit([[4, 8_000], [6, 12_000]]).model.coefficients

      assert_in_delta 0, a
      assert_in_delta 2_000, b, 1
    end

    test 'old samples fade' do
      model = fit(Array.new(30) { |i| [5 + (i % 3), (5 + (i % 3)) * 1_000] } +
                  Array.new(60) { |i| [5 + (i % 3), (5 + (i % 3)) * 2_000] }).model

      assert_in_delta 12_000, model.p50(6), 1_000
    end

    test 'p90 sits above p50 by the residual spread' do
      model = fit([[5, 9_000], [5, 11_000], [10, 19_000], [10, 21_000], [15, 29_000], [15, 31_000]]).model

      assert_operator model.p90(10), :>, model.p50(10)
      assert_operator model.p90(10) - model.p50(10), :<, 5_000
    end

    test 'the predictor uses this server when it has enough samples' do
      fit(Array.new(12) { |i| [5 + i, (5 + i) * 1_000] })
      prediction = Predictor.predict(generation, @backend)

      assert_equal 1, prediction.source
      assert_equal 'high', prediction.confidence
      assert_in_delta 10_000, prediction.execute_ms, 200
    end

    test 'the predictor scales another server by relative speed' do
      other = create_agent_backend!(owner: @alice, name: 'Other')
      fit([[5, 5_000], [10, 10_000], [20, 20_000]], other)
      set_speed(other, 1.0)
      set_speed(@backend, 2.0)
      prediction = Predictor.predict(generation, @backend.reload)

      assert_equal 3, prediction.source
      assert_in_delta 20_000, prediction.execute_ms, 200
    end

    test 'the predictor falls back to a default with low confidence' do
      prediction = Predictor.predict(generation, @backend)

      assert_equal 5, prediction.source
      assert_equal 'low', prediction.confidence
    end

    test 'the other warmness is adjusted by the cold penalty' do
      fit([[5, 15_000], [10, 20_000], [20, 30_000]], warm: false)
      BackendSpeed.create!(backend: @backend, speed_index: 1.0, cold_penalty_ms: 8_000)
      Agent::Warmth.job_finished!(@backend, 'set1')
      prediction = Predictor.predict(generation(model_set_hash: 'set1'), @backend.reload)

      assert_equal 2, prediction.source
      assert prediction.warm
      assert_in_delta 12_000, prediction.execute_ms, 200
    end

    test 'warmth ends when something else runs on ComfyUI' do
      Agent::Warmth.job_finished!(@backend, 'set1')

      assert Agent::Warmth.warm_for?(@backend, 'set1')
      Agent::Warmth.note_status!(@backend, { 'local_queue' => { 'foreign_running' => 1 } })

      assert_not Agent::Warmth.warm_for?(@backend, 'set1')
    end

    test 'the speed index is the geometric mean against the median' do
      fast = create_agent_backend!(owner: @alice, name: 'Fast')
      slow = create_agent_backend!(owner: @alice, name: 'Slow')
      fit([[5, 5_000], [10, 10_000], [20, 20_000]], @backend)
      fit([[5, 2_500], [10, 5_000], [20, 10_000]], fast)
      fit([[5, 10_000], [10, 20_000], [20, 40_000]], slow)
      SpeedIndex.recompute!

      assert_in_delta 0.5, fast.reload.speed_index, 0.01
      assert_in_delta 2.0, slow.reload.speed_index, 0.01
    end

    test 'a new server inherits the speed of a twin GPU' do
      twin = create_agent_backend!(owner: @alice, name: 'Twin')
      twin.update!(gpu_name: 'NVIDIA RTX 4090')
      set_speed(twin, 0.7)
      connect_agent!(@backend)
      agent_hello(@backend)

      assert_in_delta 0.7, @backend.reload.speed_index
    end

    test 'transfers learn throughput and fixed cost' do
      3.times { Transfers.observe!(@backend, 'input', bytes: 10.megabytes, ms: 1_000) }

      assert_in_delta 1_000, Transfers.estimate_ms(@backend, 'input', bytes: 10.megabytes), 350
    end

    test 'the timeline chains jobs and keeps waiting-for-download jobs out of the way' do
      bring_online_for!(@backend, @workflow)
      fit(Array.new(12) { |i| [5 + i, (5 + i) * 1_000] })
      first = generation(backend: @backend, queued_at: 2.minutes.ago, queue_order: 1)
      waiting = generation(backend: @backend, agent_state: 'waiting_models', queue_order: 2)
      second = generation(backend: @backend, queue_order: 3)
      Agent::Timeline.new(@backend).recompute!
      [first, waiting, second].each(&:reload)

      assert_in_delta first.predicted_end_at.to_f, second.predicted_start_at.to_f, 0.01
      assert_operator waiting.predicted_start_at, :>=, first.predicted_end_at
    end

    test 'a completed job records a sample, a fit and the prediction error' do
      bring_online_for!(@backend, @workflow)
      gen = generation(backend: @backend, agent_state: 'uploading', agent_attempt: 1, dispatched_at: 30.seconds.ago,
                       predicted_total_ms: 20_000, prediction_confidence: 'low', prediction_source: 5)
      agent_message(@backend, { 'type' => 'job.completed', 'job_id' => job_id(gen), 'outputs' => [],
                                'timings' => { 'execute_ms' => 25_000, 'nodes_total' => 6, 'nodes_cached' => 0 } })

      assert_equal 1, stat.reload.n
      log = PredictionLog.find_by!(generation: gen)

      assert_equal 20_000, log.predicted_total_ms
      assert_predicate log.abs_pct_error, :positive?
    end
  end
end
