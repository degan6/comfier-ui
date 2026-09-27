# frozen_string_literal: true

module Agent
  # Pushes a server's live state to open pages: its own page ([backend, :presence]), the status
  # cell in every servers list (:servers), and cards of jobs waiting on its downloads.
  module PresenceBroadcaster
    module_function

    def broadcast(backend)
      Turbo::StreamsChannel.broadcast_replace_later_to(
        [backend, :presence], target: "server_presence_#{backend.id}", partial: 'servers/presence', locals: { backend: }
      )
      Turbo::StreamsChannel.broadcast_replace_later_to(
        :servers, target: "server_status_#{backend.id}", partial: 'servers/status_cell', locals: { backend: }
      )
      backend.generations.where(agent_state: 'waiting_models').includes(:user).find_each do |gen|
        gen.broadcast_replace_later_to([gen.user, :generations])
      end
    end
  end
end
