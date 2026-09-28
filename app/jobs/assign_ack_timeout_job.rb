# frozen_string_literal: true

# Puts a dispatched job back at the head of its server's queue when the agent never accepted it.
class AssignAckTimeoutJob < ApplicationJob
  queue_as :default

  def perform(generation_id)
    generation = Generation.find_by(id: generation_id)
    return unless generation&.agent_state == 'dispatched' && generation.dispatched_at
    return if generation.dispatched_at > AgentTiming::ASSIGN_ACK_TIMEOUT_S.seconds.ago

    Agent::JobLifecycle.requeue_head!(generation, from: 'dispatched')
  end
end
