# frozen_string_literal: true

# Moves waiting jobs to a server that would finish them clearly sooner: more than 25% and more
# than 30s earlier, at most MAX_MOVES times, never for pinned jobs, and never once most of a job's
# downloads are done.
class RebalanceJob < ApplicationJob
  MIN_GAIN_RATIO = 0.25
  MIN_GAIN_S = 30

  queue_as :default

  def perform
    return unless Agent::Store.once_per?('rebalance', ttl: AgentTiming::REBALANCE_INTERVAL_S - 1)

    Generation.where(agent_state: %w[queued waiting_models], pinned_backend_id: nil)
              .where(agent_moves: ...GenerationAgent::MAX_MOVES).includes(:user, :backend, :workflow)
              .find_each { consider(it) }
  end

  private

  def consider(gen)
    return unless movable?(gen)

    best = Agent::Router.new(gen).candidates.reject { it.backend.id == gen.backend_id }.min_by(&:finish_at)
    move!(gen, best.backend) if best && worth_moving?(gen, best)
  end

  def movable?(gen)
    return false if gen.backend.nil? || gen.predicted_end_at.nil? || downloads_mostly_done?(gen)

    BackendPolicy.new(gen.user).affinity != 'mine_only' || gen.backend.owned_by?(gen.user)
  end

  def worth_moving?(gen, best)
    remaining = gen.predicted_end_at - Time.current
    gain = gen.predicted_end_at - best.finish_at
    remaining.positive? && gain > MIN_GAIN_S && gain > remaining * MIN_GAIN_RATIO
  end

  def downloads_mostly_done?(gen)
    return false unless gen.agent_state == 'waiting_models'

    downloads = ModelDownload.agent_pending.where('for_generation_ids @> ?', [gen.id].to_json).to_a
    total = downloads.sum { it.bytes_total.to_i }
    total.positive? && downloads.sum { it.bytes_done.to_i } > total / 2
  end

  def move!(gen, target)
    old = gen.backend
    return unless gen.agent_transition!(from: gen.agent_state, to: 'routing', backend_id: nil,
                                        agent_moves: gen.agent_moves + 1)

    Agent::DownloadPlanner.release_generation!(gen)
    begin
      Agent::Router.route!(gen, only: target)
    rescue Agent::Router::UnroutableError
      Agent::JobLifecycle.route!(gen)
    end
    Agent::Timeline.schedule(old)
  end
end
