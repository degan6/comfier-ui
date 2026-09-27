# frozen_string_literal: true

# Refreshes cached workflow availability after a server's inventory or a workflow's requirements
# change.
class RecomputeAvailabilityJob < ApplicationJob
  queue_as :default

  def perform(backend_id: nil, workflow_id: nil)
    if backend_id && (backend = Backend.find_by(id: backend_id))
      Agent::Availability.recompute_for_backend!(backend)
    end
    return unless workflow_id && (workflow = Workflow.find_by(id: workflow_id))

    Agent::Availability.recompute_for_workflow!(workflow)
  end
end
