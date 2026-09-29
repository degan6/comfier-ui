require 'test_helper'

module LiteLlm
  class ClientTest < ActiveSupport::TestCase
    setup do
      @previous = {
        'LITELLM_URL' => ENV.fetch('LITELLM_URL', nil),
        'LITELLM_API_KEY' => ENV.fetch('LITELLM_API_KEY', nil),
        'LITELLM_MODEL' => ENV.fetch('LITELLM_MODEL', nil),
        'LITELLM_TIMEOUT_SECONDS' => ENV.fetch('LITELLM_TIMEOUT_SECONDS', nil)
      }
    end

    teardown do
      @previous.each { |key, value| ENV[key] = value }
    end

    test 'configured when url and model are set' do
      with_env('LITELLM_URL' => 'http://litellm.test', 'LITELLM_MODEL' => 'gpt-test') do
        assert_predicate Client, :configured?
        assert_empty Client.missing_config_keys
      end
    end

    test 'chat sends an OpenAI-compatible request and returns the message content' do
      with_env('LITELLM_URL' => 'http://litellm.test/', 'LITELLM_MODEL' => 'gpt-test',
               'LITELLM_API_KEY' => 'secret') do
        stub_request(:post, 'http://litellm.test/v1/chat/completions')
          .with(headers: { 'Authorization' => 'Bearer secret' }) do |request|
            body = JSON.parse(request.body)

            assert_equal 'gpt-test', body['model']
            assert_equal 'json_object', body.dig('response_format', 'type')
            assert_equal 'system rules', body.dig('messages', 0, 'content')
            assert_equal 'user payload', body.dig('messages', 1, 'content')
          end
          .to_return(body: { choices: [{ message: { content: '{"ok":true}' } }] }.to_json)

        assert_equal '{"ok":true}', Client.chat(system: 'system rules', user: 'user payload')
      end
    end

    test 'chat records an activity log entry on success' do
      with_env('LITELLM_URL' => 'http://litellm.test/', 'LITELLM_MODEL' => 'gpt-test') do
        stub_request(:post, 'http://litellm.test/v1/chat/completions')
          .to_return(body: { choices: [{ message: { content: '{"ok":true}' } }] }.to_json)

        Client.chat(system: 'system rules', user: 'user payload')
        log = ActivityLog.order(:id).last

        assert_equal 'llm_chat', log.kind
        assert log.details['success']
        assert_equal 'system rules', log.details.dig('request', 'messages', 0, 'content')
        assert_equal '{"ok":true}', log.details['assistant_content']
      end
    end

    test 'chat can send earlier turns, a temperature and a JSON schema' do
      with_env('LITELLM_URL' => 'http://litellm.test', 'LITELLM_MODEL' => 'gpt-test') do
        schema = { type: 'object', properties: {}, additionalProperties: false }
        stub_request(:post, 'http://litellm.test/v1/chat/completions')
          .with do |request|
            body = JSON.parse(request.body)

            assert_equal 0, body['temperature']
            assert_equal %w[system user assistant user], body['messages'].pluck('role')
            assert_equal({ 'type' => 'json_schema',
                           'json_schema' => { 'name' => 'reply', 'strict' => true, 'schema' => schema.as_json } },
                         body['response_format'])
          end
          .to_return(body: { choices: [{ message: { content: '{}' } }] }.to_json)

        history = [{ role: 'user', content: 'first' }, { role: 'assistant', content: '{"bad":1}' }]

        assert_equal '{}', Client.chat(system: 's', user: 'fix it', history:, temperature: 0,
                                       json_schema: { name: 'reply', schema: })
      end
    end

    test 'raises on HTTP errors' do
      with_env('LITELLM_URL' => 'http://litellm.test', 'LITELLM_MODEL' => 'gpt-test') do
        stub_request(:post, 'http://litellm.test/v1/chat/completions').to_return(status: 500, body: 'nope')

        error = assert_raises(Error) { Client.chat(system: 'x', user: 'y') }

        assert_match(/HTTP 500/, error.message)
      end
    end

    test 'preprocessing uses chat with thinking disabled and plain text output' do
      with_env('LITELLM_URL' => 'http://litellm.test', 'LITELLM_MODEL' => nil) do
        stub_request(:post, 'http://litellm.test/v1/chat/completions')
          .with do |request|
            body = JSON.parse(request.body)
            body['model'] == 'chat' && body['max_tokens'] == 512 && !body.key?('response_format') &&
              body.dig('extra_body', 'chat_template_kwargs', 'enable_thinking') == false
          end
          .to_return(body: { choices: [{ finish_reason: 'stop', message: { content: '  A bright shop.  ' } }] }.to_json)

        assert_equal 'A bright shop.', Client.preprocess_prompt(system: 'Rewrite.', user: 'Lyrics')
      end
    end

    test 'preprocessing rejects empty and truncated responses' do
      with_env('LITELLM_URL' => 'http://litellm.test') do
        [%w[length unfinished], ['stop', '   '], ['content_filter', 'blocked']].each do |finish, content|
          stub_request(:post, 'http://litellm.test/v1/chat/completions')
            .to_return(body: { choices: [{ finish_reason: finish, message: { content: } }] }.to_json)

          assert_raises(Error) { Client.preprocess_prompt(system: 'Rewrite.', user: 'Lyrics') }
        end
      end
    end

    test 'raises when the proxy cannot be reached' do
      with_env('LITELLM_URL' => 'http://litellm.test', 'LITELLM_MODEL' => 'gpt-test') do
        stub_request(:post, 'http://litellm.test/v1/chat/completions').to_raise(Errno::ECONNREFUSED)

        error = assert_raises(Error) { Client.chat(system: 'x', user: 'y') }

        assert_match(/Couldn't reach LiteLLM/, error.message)
      end
    end
  end
end
