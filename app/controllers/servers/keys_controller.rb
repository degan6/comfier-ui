module Servers
  # Rotating and revoking a server's agent keys. A new key is shown once, on the response to the
  # request that created it, and never stored anywhere readable.
  class KeysController < ApplicationController
    before_action :set_backend

    rate_limit to: 5, within: 1.hour, only: %i[create rotate], by: -> { current_user.id },
               with: -> { redirect_to server_path(params[:server_id]), alert: 'Too many new keys. Try again later.' }

    def create = rotate

    def rotate
      immediately = ActiveModel::Type::Boolean.new.cast(params[:revoke_immediately])
      @new_key = Agent::KeyRotation.rotate!(@backend, revoke_immediately: immediately)
      ActivityLog.record(kind: :server_key_rotated, user: current_user, subject: @backend, request:,
                         message: "Rotated the key for #{@backend.name}#{' and revoked the old one' if immediately}")
      render 'servers/setup', status: :created
    end

    def destroy
      key = @backend.backend_keys.find(params[:id])
      Agent::KeyRotation.revoke!(key)
      ActivityLog.record(kind: :server_key_revoked, user: current_user, subject: @backend, request:,
                         message: "Revoked key #{key.display} for #{@backend.name}")
      redirect_to server_path(@backend), notice: 'Key revoked. The server was disconnected.', status: :see_other
    end

    private

    def set_backend
      @backend = Backend.agent.kept.find(params[:server_id])
      head :not_found unless BackendPolicy.new(current_user).can_manage?(@backend)
    end
  end
end
