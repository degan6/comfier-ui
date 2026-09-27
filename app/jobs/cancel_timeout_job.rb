# frozen_string_literal: true

# Ends a cancel the agent never confirmed.
class CancelTimeoutJob < ApplicationJob
  queue_as :default

  def perform(generation_id)
    generation = Generation.find_by(id: generation_id)
    return unless generation&.agent_state == 'cancelling'

    Agent::JobLifecycle.finish_cancel!(generation)
    Agent::Dispatcher.dispatch_for!(generation.backend) if generation.backend
  end
end
