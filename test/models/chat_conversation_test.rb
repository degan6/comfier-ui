require 'test_helper'

class ChatConversationTest < ActiveSupport::TestCase
  setup do
    @previous = {
      'LITELLM_URL' => ENV.fetch('LITELLM_URL', nil),
      'LITELLM_MODEL' => ENV.fetch('LITELLM_MODEL', nil)
    }
    ENV['LITELLM_URL'] = 'http://litellm.test'
    ENV['LITELLM_MODEL'] = 'gpt-test'
  end

  teardown do
    @previous.each { |key, value| ENV[key] = value }
  end

  test 'composer_locals uses the LiteLLM model catalog' do
    stub_request(:get, 'http://litellm.test/v1/models')
      .to_return(body: { data: [{ id: 'gpt-test' }, { id: 'vision-model' }] }.to_json)

    conversation = chat_conversations(:alice_chat)
    locals = conversation.composer_locals

    assert_equal %w[gpt-test vision-model], locals.fetch(:chat_models)
    assert_equal conversation, locals.fetch(:conversation)
  end
end
