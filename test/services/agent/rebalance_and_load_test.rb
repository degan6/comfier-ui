# frozen_string_literal: true

require 'test_helper'

module Agent
  class RebalanceAndLoadTest < ActiveSupport::TestCase
    setup do
      @alice = users(:alice)
      @workflow = workflows(:sd_image)
      @backend = create_agent_backend!(owner: @alice)
    end

    def queued_on(backend, end_in:, **attrs)
      Generation.create!({ user: @alice, workflow: @workflow, prompt: 'x', kind: :image, status: :queued, backend:,
                           agent_state: 'queued', structure_hash: 'sd15', work_units: 1,
                           filled_workflow_json: { '1' => {} }, predicted_end_at: end_in.from_now }.merge(attrs))
    end

    test 'a job moves when another server finishes it much sooner' do
      fast = create_agent_backend!(owner: @alice, name: 'Fast')
      [@backend, fast].each { bring_online_for!(it, @workflow) }
      gen = queued_on(@backend, end_in: 20.minutes)
      RebalanceJob.perform_now

      assert_equal fast.id, gen.reload.backend_id
      assert_equal 1, gen.agent_moves
    end

    test 'small gains do not move jobs' do
      other = create_agent_backend!(owner: @alice, name: 'Other')
      [@backend, other].each { bring_online_for!(it, @workflow) }
      gen = queued_on(@backend, end_in: 20.seconds)
      RebalanceJob.perform_now

      assert_equal @backend.id, gen.reload.backend_id
    end

    test 'pinned jobs and jobs at the move limit stay put' do
      fast = create_agent_backend!(owner: @alice, name: 'Fast')
      [@backend, fast].each { bring_online_for!(it, @workflow) }
      pinned = queued_on(@backend, end_in: 20.minutes, pinned_backend_id: @backend.id)
      moved = queued_on(@backend, end_in: 20.minutes, agent_moves: GenerationAgent::MAX_MOVES)
      RebalanceJob.perform_now

      assert_equal @backend.id, pinned.reload.backend_id
      assert_equal @backend.id, moved.reload.backend_id
    end

    test 'status intervals add up per minute, capped at 60 seconds' do
      travel_to Time.utc(2026, 9, 27, 12, 0, 5) do
        bring_online!(@backend)
      end
      travel_to Time.utc(2026, 9, 27, 12, 0, 25) do
        agent_status(@backend, state: 'busy')
      end
      travel_to Time.utc(2026, 9, 27, 12, 0, 45) do
        agent_status(@backend, state: 'idle')
      end
      row = BackendLoadMinute.find_by!(backend: @backend, minute: Time.utc(2026, 9, 27, 12, 0))

      assert_equal 40, row.online_s
      assert_equal 20, row.busy_s
      LoadMinute.add!(@backend, Time.utc(2026, 9, 27, 12, 0, 50), online_s: 50)

      assert_equal 60, row.reload.online_s
    end

    test 'minutes roll up into hours and old rows are dropped' do
      LoadMinute.add!(@backend, Time.utc(2026, 9, 27, 10, 1), online_s: 60, busy_s: 30, jobs_completed: 1)
      LoadMinute.add!(@backend, Time.utc(2026, 9, 27, 10, 2), online_s: 60, busy_s: 60, jobs_completed: 2)
      LoadMinute.add!(@backend, 40.days.ago, online_s: 60)
      LoadRollupJob.perform_now(Time.utc(2026, 9, 27, 11, 30))
      hour = BackendLoadHour.find_by!(backend: @backend, hour: Time.utc(2026, 9, 27, 10))

      assert_equal 120, hour.online_s
      assert_equal 3, hour.jobs_completed
      assert_in_delta 0.75, LoadMinute.utilization([hour])
      assert_not BackendLoadMinute.exists?(minute: ...30.days.ago)
    end

    test 'server charts return utilization series' do
      LoadMinute.add!(@backend, 10.minutes.ago, online_s: 60, busy_s: 30)
      data = ServerCharts.new(@backend).load(range: 'day')

      assert_includes data[:utilization][:datasets].first[:data], 50.0
      assert data.key?(:jobs)
    end
  end
end
