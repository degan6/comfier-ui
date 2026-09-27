# frozen_string_literal: true

# Every 10s: agent servers whose presence expired (no status for OFFLINE_AFTER_S) are marked
# offline, which starts their lease clock.
class OfflineSweepJob < ApplicationJob
  queue_as :default

  def perform
    Backend.agent.kept.where(offline_since: nil).where.not(connected_at: nil).find_each do |backend|
      next if Agent::Presence.online?(backend)

      Agent::Presence.mark_offline!(backend, reason: Agent::Presence.connected?(backend) ? 'no_status' : 'disconnected')
    end
  end
end
