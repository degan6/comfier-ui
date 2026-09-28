# frozen_string_literal: true

# Runs the delayed half of reconnect reconciliation for an agent server.
class ReconcileBackendJob < ApplicationJob
  queue_as :default

  def perform(backend_id, hello_at = nil)
    backend = Backend.find_by(id: backend_id)
    return unless backend&.agent?

    Agent::Reconciliation.run!(backend, hello_at:)
  end
end
