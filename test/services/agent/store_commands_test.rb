# frozen_string_literal: true

require 'test_helper'

module Agent
  class StoreCommandsTest < ActiveSupport::TestCase
    test 'keys expire after their ttl' do
      Store.write_json('x', { 'a' => 1 }, ttl: 5)

      assert_equal({ 'a' => 1 }, Store.read_json('x'))
      travel 6.seconds do
        assert_nil Store.read_json('x')
      end
    end

    test 'once_per? is true once per window' do
      assert Store.once_per?('debounce', ttl: 1)
      assert_not Store.once_per?('debounce', ttl: 1)
      travel 2.seconds do
        assert Store.once_per?('debounce', ttl: 1)
      end
    end

    test 'count_within counts inside the window only' do
      3.times { Store.count_within('c', ttl: 60) }

      assert_equal 3, Store.read_json('c')
      travel 61.seconds do
        assert_equal 1, Store.count_within('c', ttl: 60)
      end
    end

    test 'a command for a socket held here runs directly' do
      backend = create_agent_backend!(owner: users(:alice))
      socket = connect_agent!(backend)

      Commands.send_message(backend.id, { 'type' => 'inventory.refresh' })

      assert_equal ['inventory.refresh'], socket.sent.pluck('type')
    end

    test 'a command from another process goes through the channel to the socket holder' do
      backend = create_agent_backend!(owner: users(:alice))
      published = []
      Store.subscribe(Commands::CHANNEL) { published << JSON.parse(it) }

      Commands.send_message(backend.id, { 'type' => 'config.pause' })

      assert_equal [{ 'op' => 'send', 'backend_id' => backend.id, 'message' => { 'type' => 'config.pause' } }],
                   published

      socket = connect_agent!(backend)
      CommandSubscriber.ensure_started!
      Store.publish(Commands::CHANNEL, JSON.generate(published.first))

      assert_equal ['config.pause'], socket.sent.pluck('type')
    end

    test 'a process without the socket ignores published commands' do
      backend = create_agent_backend!(owner: users(:alice))

      assert_nil Commands.execute_payload(JSON.generate('op' => 'send', 'backend_id' => backend.id,
                                                        'message' => { 'type' => 'config.pause' }))
    end

    test 'close is delivered with its code' do
      backend = create_agent_backend!(owner: users(:alice))
      socket = connect_agent!(backend)

      Commands.close(backend.id, 4401, 'key revoked')

      assert_equal 4401, socket.close_code
    end

    test 'invalid outbound messages raise in tests' do
      assert_raises(ProtocolValidator::ValidationError) do
        Commands.send_message(1, { 'type' => 'job.cancel' })
      end
    end

    test 'hub replacement closes the old socket with 4409 and counts toward flapping' do
      backend = create_agent_backend!(owner: users(:alice))
      first = connect_agent!(backend)
      5.times { connect_agent!(backend) }

      assert_equal 4409, first.close_code
      assert Hub.flapping?(backend)
    end

    test 'a replaced socket closing late does not drop its replacement' do
      backend = create_agent_backend!(owner: users(:alice))
      old = connect_agent!(backend)
      current = connect_agent!(backend)

      assert_not Hub.instance.disconnect!(backend.id, old)
      assert_equal current, Hub.instance.socket(backend.id)
    end
  end
end
