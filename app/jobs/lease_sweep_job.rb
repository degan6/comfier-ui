# frozen_string_literal: true

# Every 15s: servers offline for LEASE_GRACE_S lose their jobs. The running job is lost (retried
# elsewhere if the budget allows); queued and waiting jobs are routed again, except pinned jobs
# and jobs from users who only use their own servers, which keep waiting.
class LeaseSweepJob < ApplicationJob
  queue_as :default

  def perform
    Backend.agent.kept.where(offline_since: ...AgentTiming::LEASE_GRACE_S.seconds.ago).find_each do |backend|
      next if Agent::Presence.online?(backend)

      expire!(backend)
    end
  end

  private

  def expire!(backend)
    backend.generations.agent_on_server.find_each { Agent::JobLifecycle.lost!(it, reason: 'lease_expired') }
    backend.generations.where(agent_state: %w[queued waiting_models]).includes(:user).find_each do |gen|
      next if gen.pinned_backend_id == backend.id || BackendPolicy.new(gen.user).affinity == 'mine_only'

      Agent::JobLifecycle.reroute!(gen, exclude: nil, from: %w[queued waiting_models])
    end
  end
end
