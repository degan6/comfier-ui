# JSON series for the charts on a server's page. Each chart gets labels plus one or more
# datasets; the chart Stimulus controller draws them.
class ServerCharts
  RANGES = { 'day' => 24.hours, 'week' => 7.days, 'month' => 30.days }.freeze

  def initialize(backend)
    @backend = backend
  end

  def load(range: 'day')
    span = RANGES.fetch(range.to_s, RANGES['day'])
    rows = span > 2.days ? hourly(span) : minutes_as_hours(span)
    {
      utilization: {
        labels: rows.map { it[:at].iso8601 },
        datasets: [
          { label: 'Comfier jobs', data: rows.map { percent(it[:busy_s], it[:online_s]) } },
          { label: 'Local use', data: rows.map { percent(it[:busy_local_s], it[:online_s]) }, muted: true }
        ]
      },
      jobs: daily_jobs(span)
    }
  end

  def performance
    stats = @backend.perf_stats.includes(:workflow).where(n: Perf::Model::MIN_FIT_N..).order(n: :desc).limit(12)
    {
      labels: stats.map { "#{it.workflow&.name || it.structure_hash.first(8)}#{' (warm)' if it.warm}" },
      datasets: [{ label: 'Typical run (s)',
                   data: stats.map { (it.model.p50(it.median_work_units || 1) / 1000.0).round(1) } }]
    }
  end

  private

  def percent(part, whole) = whole.to_f.positive? ? ((part.to_f / whole) * 100).round(1) : 0

  def hourly(span)
    @backend.backend_load_hours.where(hour: span.ago..).order(:hour).map do |row|
      { at: row.hour, online_s: row.online_s, busy_s: row.busy_s, busy_local_s: row.busy_local_s,
        jobs: row.jobs_completed }
    end + minutes_as_hours(Time.current - Time.current.utc.beginning_of_hour, since: Time.current.utc.beginning_of_hour)
  end

  def minutes_as_hours(span, since: span.ago)
    by_hour = @backend.backend_load_minutes.where(minute: since..).group_by { it.minute.beginning_of_hour }
    by_hour.sort.map do |hour, rows|
      { at: hour, online_s: rows.sum(&:online_s), busy_s: rows.sum(&:busy_s),
        busy_local_s: rows.sum(&:busy_local_s), jobs: rows.sum(&:jobs_completed) }
    end
  end

  def daily_jobs(span)
    days = [(span / 1.day).ceil, 1].max
    recent = @backend.job_attempts.where(created_at: days.days.ago.utc.beginning_of_day..)
    labels = (0...days).map { (days - 1 - it).days.ago.utc.to_date.iso8601 }
    {
      labels:,
      datasets: [
        { label: 'Completed', data: per_day(recent.where(outcome: 'completed'), labels) },
        { label: 'Failed', data: per_day(recent.failures, labels), danger: true }
      ]
    }
  end

  def per_day(scope, labels)
    counts = scope.group("to_char(created_at, 'YYYY-MM-DD')").count
    labels.map { counts[it] || 0 }
  end
end
