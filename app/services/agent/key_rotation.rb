# frozen_string_literal: true

module Agent
  # New keys replace old ones with a grace period (so the owner can update the server), or at
  # once. Revoking disconnects a live agent with 4401.
  module KeyRotation
    CLOSE_REVOKED = 4401

    module_function

    def rotate!(backend, revoke_immediately: false)
      old_keys = backend.backend_keys.active.to_a
      full = backend.issue_agent_key!
      if revoke_immediately
        old_keys.each { revoke!(it) }
      else
        old_keys.each { it.update!(expires_at: [it.expires_at, BackendKey::ROTATION_GRACE.from_now].compact.min) }
      end
      full
    end

    def revoke!(key)
      key.revoke!
      Commands.close(key.backend_id, CLOSE_REVOKED, 'key revoked')
    end
  end
end
