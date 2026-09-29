require 'test_helper'

class ChatReplyJobTest < ActiveJob::TestCase
  setup do
    @previous = {
      'LITELLM_URL' => ENV.fetch('LITELLM_URL', nil),
      'LITELLM_MODEL' => ENV.fetch('LITELLM_MODEL', nil)
    }
    ENV['LITELLM_URL'] = 'http://litellm.test'
    ENV['LITELLM_MODEL'] = 'gpt-test'
    Rails.cache.delete(LiteLlm::ModelsCatalog::CACHE_KEY)
    stub_request(:get, 'http://litellm.test/v1/models')
      .to_return(body: { data: [{ id: 'gpt-test' }] }.to_json)
  end

  teardown do
    @previous.each { |key, value| ENV[key] = value }
    Rails.cache.delete(LiteLlm::ModelsCatalog::CACHE_KEY)
  end

  test 'fills in a pending assistant message' do
    conversation = chat_conversations(:alice_chat)
    pending = conversation.chat_messages.create!(role: :assistant, status: :pending, content: '')

    stub_request(:post, 'http://litellm.test/v1/chat/completions')
      .to_return(body: { choices: [{ message: { content: 'Hello back' } }] }.to_json)

    ChatReplyJob.perform_now(pending.id)

    assert_equal 'succeeded', pending.reload.status
    assert_equal 'Hello back', pending.content
  end

  test 'marks the assistant message failed when LiteLLM errors' do
    conversation = chat_conversations(:alice_chat)
    pending = conversation.chat_messages.create!(role: :assistant, status: :pending, content: '')

    stub_request(:post, 'http://litellm.test/v1/chat/completions').to_return(status: 500, body: 'nope')

    ChatReplyJob.perform_now(pending.id)

    assert_equal 'failed', pending.reload.status
    assert_match(/HTTP 500/, pending.error)
  end
end
