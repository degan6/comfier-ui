# frozen_string_literal: true

module Agent
  # Adds the time since the previous status into this minute's load row: online always, busy when
  # a Comfier job was running, busy_local when ComfyUI was in local use.
  module LoadMinute
    MAX_INTERVAL_S = AgentTiming::OFFLINE_AFTER_S

    module_function

    def record!(backend, status, previous: nil)
      seconds = interval(previous)
      return if seconds <= 0

      state = previous&.dig('state') || status['state']
      queue_len = backend.generations.agent_waiting.count
      add!(backend, Time.current, online_s: seconds, busy_s: state == 'busy' ? seconds : 0,
                                  busy_local_s: state == 'busy_local' ? seconds : 0, queue_len:)
    end

    def job_completed!(backend) = add!(backend, Time.current, jobs_completed: 1)

    def add!(backend, at, online_s: 0, busy_s: 0, busy_local_s: 0, queue_len: 0, jobs_completed: 0) # rubocop:disable Metrics/ParameterLists
      binds = [backend.id, at.utc.beginning_of_minute, online_s, busy_s, busy_local_s, queue_len, jobs_completed]
      BackendLoadMinute.connection.exec_query(<<~SQL.squish, 'LoadMinute', binds)
        INSERT INTO backend_load_minutes (backend_id, minute, online_s, busy_s, busy_local_s, queue_len_max, jobs_completed)
        VALUES ($1, $2, $3, $4, $5, $6, $7)
        ON CONFLICT (backend_id, minute) DO UPDATE SET
          online_s = LEAST(backend_load_minutes.online_s + EXCLUDED.online_s, 60),
          busy_s = LEAST(backend_load_minutes.busy_s + EXCLUDED.busy_s, 60),
          busy_local_s = LEAST(backend_load_minutes.busy_local_s + EXCLUDED.busy_local_s, 60),
          queue_len_max = GREATEST(backend_load_minutes.queue_len_max, EXCLUDED.queue_len_max),
          jobs_completed = backend_load_minutes.jobs_completed + EXCLUDED.jobs_completed
      SQL
    end

    def interval(previous)
      return 0 unless previous && previous['at']

      (Time.current - Time.zone.parse(previous['at'])).clamp(0, MAX_INTERVAL_S)
    rescue ArgumentError
      0
    end

    # Share of online time spent on Comfier jobs, from minute or hour rows.
    def utilization(rows)
      online = rows.sum(&:online_s)
      online.positive? ? rows.sum(&:busy_s) / online : 0.0
    end
  end
end
