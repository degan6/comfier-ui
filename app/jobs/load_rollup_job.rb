# frozen_string_literal: true

# Nightly: roll minute load rows into hours, then drop minutes older than 30 days and hours older
# than a year.
class LoadRollupJob < ApplicationJob
  MINUTE_RETENTION = 30.days
  HOUR_RETENTION = 1.year

  queue_as :default

  def perform(now = Time.current)
    rollup!(before: now.utc.beginning_of_hour)
    BackendLoadMinute.where(minute: ...MINUTE_RETENTION.ago).delete_all
    BackendLoadHour.where(hour: ...HOUR_RETENTION.ago).delete_all
  end

  def rollup!(before:)
    BackendLoadMinute.connection.exec_query(<<~SQL.squish, 'LoadRollup', [before])
      INSERT INTO backend_load_hours (backend_id, hour, online_s, busy_s, busy_local_s, queue_len_max, jobs_completed)
      SELECT backend_id, date_trunc('hour', minute), SUM(online_s), SUM(busy_s), SUM(busy_local_s),
             MAX(queue_len_max), SUM(jobs_completed)
      FROM backend_load_minutes WHERE minute < $1
      GROUP BY backend_id, date_trunc('hour', minute)
      ON CONFLICT (backend_id, hour) DO UPDATE SET
        online_s = EXCLUDED.online_s, busy_s = EXCLUDED.busy_s, busy_local_s = EXCLUDED.busy_local_s,
        queue_len_max = EXCLUDED.queue_len_max, jobs_completed = EXCLUDED.jobs_completed
    SQL
  end
end
