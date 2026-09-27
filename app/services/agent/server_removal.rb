# frozen_string_literal: true

module Agent
  # Soft-deletes an agent server: keys revoked, socket closed with 4401, the running job lost,
  # waiting jobs routed elsewhere, downloads dropped. Generations and stats are kept.
  module ServerRemoval
    module_function

    def call(backend)
      backend.soft_delete!
      Commands.close(backend.id, KeyRotation::CLOSE_REVOKED, 'server deleted')
      Presence.mark_offline!(backend, reason: 'deleted')
      backend.generations.agent_on_server.find_each { JobLifecycle.lost!(it, reason: 'server_deleted') }
      backend.generations.where(agent_state: %w[queued waiting_models]).find_each do |gen|
        JobLifecycle.reroute!(gen, exclude: backend, from: %w[queued waiting_models])
      end
      backend.model_downloads.where(agent_state: 'queued').find_each do |download|
        download.update!(agent_state: 'cancelled', status: :failed, error_message: 'The server was deleted.')
      end
    end
  end
end
