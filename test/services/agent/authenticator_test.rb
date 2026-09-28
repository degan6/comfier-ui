# frozen_string_literal: true

require 'test_helper'

module Agent
  class AuthenticatorTest < ActiveSupport::TestCase
    setup do
      @backend = create_agent_backend!(owner: users(:alice))
      @token = create_agent_key!(@backend)
    end

    def authenticate(token = @token) = Authenticator.from_header("Bearer #{token}", ip: '127.0.0.1')

    test 'a valid key authenticates and records its use' do
      result = authenticate

      assert_equal @backend, result.backend
      assert_equal '127.0.0.1', result.backend_key.reload.last_ip
    end

    test 'wrong and missing tokens raise' do
      assert_raises(Authenticator::AuthenticationError) { authenticate('cmf_nope') }
      assert_raises(Authenticator::AuthenticationError) { Authenticator.from_header(nil) }
      assert_raises(Authenticator::AuthenticationError) { authenticate("#{@token}x") }
    end

    test 'a revoked key raises and records why' do
      @backend.backend_keys.first.revoke!

      assert_raises(Authenticator::AuthenticationError) { authenticate }
      assert_equal 'revoked', @backend.backend_keys.first.last_rejected_reason
    end

    test 'a rotated key keeps working through the grace period' do
      new_token = KeyRotation.rotate!(@backend)

      assert_equal @backend, authenticate.backend
      assert_equal @backend, authenticate(new_token).backend
      travel BackendKey::ROTATION_GRACE + 1.minute do
        assert_raises(Authenticator::AuthenticationError) { authenticate }
        assert_equal 'expired', @backend.backend_keys.find_by(prefix: KeyService.prefix_of(@token)).last_rejected_reason
        assert_equal @backend, authenticate(new_token).backend
      end
    end

    test 'rotating with immediate revoke disconnects the agent with 4401' do
      socket = connect_agent!(@backend)
      KeyRotation.rotate!(@backend, revoke_immediately: true)

      assert_equal 4401, socket.close_code
      assert_raises(Authenticator::AuthenticationError) { authenticate }
    end

    test 'keys of deleted servers are refused' do
      ServerRemoval.call(@backend)

      assert_raises(Authenticator::AuthenticationError) { authenticate }
    end
  end
end
