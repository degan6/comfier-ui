module Admin
  # Every agent server at a glance, and how accurate predictions have been.
  class ServerOverviewController < BaseController
    def show
      @servers = Backend.agent.kept.includes(:owner_user, :backend_speed).ordered.to_a
      @queue_total = Generation.agent_waiting.count
      @running_total = Generation.agent_on_server.count
      @failure_rates = failure_rates
      @flapping = @servers.select { Agent::Hub.flapping?(it.id) }
      @jobs_per_hour = jobs_per_hour
      @accuracy = accuracy_by(:backend_id, 7.days)
    end

    def accuracy
      @by_backend = { 7 => accuracy_by(:backend_id, 7.days), 30 => accuracy_by(:backend_id, 30.days) }
      @by_type = { 7 => accuracy_by(:structure_hash, 7.days), 30 => accuracy_by(:structure_hash, 30.days) }
      @backends = Backend.where(id: @by_backend[30].keys).index_by(&:id)
      @type_names = PerfStat.where(structure_hash: @by_type[30].keys).includes(:workflow)
                            .to_h { [it.structure_hash, it.workflow&.name] }
    end

    private

    def failure_rates
      JobAttempt.where(created_at: 7.days.ago..).group(:backend_id, :outcome).count
                .each_with_object(Hash.new { |h, k| h[k] = [0, 0] }) do |((backend_id, outcome), count), acc|
        acc[backend_id][1] += count
        acc[backend_id][0] += count if %w[failed lost timeout].include?(outcome)
      end
    end

    def jobs_per_hour
      counts = JobAttempt.where(outcome: 'completed', created_at: 24.hours.ago..)
                         .group("date_trunc('hour', created_at)").count
      hours = (0...24).map { (23 - it).hours.ago.utc.beginning_of_hour }
      { labels: hours.map(&:iso8601), datasets: [{ label: 'Jobs', data: hours.map { counts[it] || 0 } }] }
    end

    # Median absolute percentage error, grouped.
    def accuracy_by(column, window)
      scope = PredictionLog.where(created_at: window.ago..).where.not(column => nil)
      scope.group_by(&column).transform_values do |logs|
        errors = logs.filter_map(&:abs_pct_error).sort
        errors.empty? ? nil : { median: errors[errors.size / 2].round, n: errors.size }
      end.compact
    end
  end
end
