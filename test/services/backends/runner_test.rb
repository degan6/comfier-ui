require 'test_helper'

module Backends
  class RunnerTest < ActiveSupport::TestCase
    def generation(user = users(:alice))
      Generation.new(user:, workflow: workflows(:sd_image), prompt: 'x', kind: :image)
    end

    test 'users without agent servers use legacy backends' do
      assert_instance_of LegacyRunner, Runner.for(generation)
    end

    test 'users who can use an agent server submit to agents' do
      create_agent_backend!(owner: users(:bob), visibility: 'public')

      assert_instance_of AgentRunner, Runner.for(generation)
    end

    test 'a submitted agent job routes and cancels through the agent runner' do
      backend = create_agent_backend!(owner: users(:alice))
      bring_online_for!(backend, workflows(:sd_image))
      gen = generation
      gen.save!
      Runner.for(gen).submit(gen)

      assert_equal 'queued', gen.reload.agent_state
      assert_predicate gen.work_units, :positive?
      assert_predicate gen.structure_hash, :present?

      assert GenerationCanceller.call(gen).cancelled
      assert_equal 'cancelled', gen.reload.agent_state
    end

    test 'refreshing an agent inventory asks the agent' do
      backend = create_agent_backend!(owner: users(:alice))
      socket = connect_agent!(backend)
      Runner.for_backend(backend).refresh_inventory(backend)

      assert socket.last_of_type('inventory.refresh')
    end
  end
end
