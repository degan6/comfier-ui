# Sends a queued generation to a server through whichever runner handles it.
class SubmitGenerationJob < ApplicationJob
  queue_as :default

  def perform(generation)
    return unless pending_submission?(generation)
    return generation.fail!('The workflow for this generation was removed') if generation.workflow.nil?

    PromptPreprocessor.call(generation)
    return unless pending_submission?(generation.reload)

    Backends::Runner.for(generation).submit(generation)
  rescue BackendSelector::NoBackendAvailable, Agent::Router::UnroutableError, Comfyui::Error,
         WorkflowRenderer::MissingValue, PromptPreprocessor::Error => e
    fail_generation(generation, e.message) if generation.reload.queued?
  end

  private

  def pending_submission?(generation)
    generation.queued? && generation.agent_state.nil?
  end

  def fail_generation(generation, message)
    return generation.fail!(message) unless generation.agent_job?

    generation.agent_transition!(from: Generation::WAITING_STATES, to: 'failed', error_message: message.truncate(1000))
  end
end
