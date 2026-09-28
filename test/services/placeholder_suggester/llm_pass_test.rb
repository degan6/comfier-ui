require 'test_helper'

class PlaceholderSuggester
  class LlmPassTest < ActiveSupport::TestCase
    COMPLETIONS = 'http://litellm.test/v1/chat/completions'.freeze
    GRAPH = {
      '6' => { 'class_type' => 'CLIPTextEncode', '_meta' => { 'title' => 'Mystery' },
               'inputs' => { 'text' => "line one\n\"quoted\"" } },
      '8' => { 'class_type' => 'ImageScale', '_meta' => { 'title' => 'ImageScale' },
               'inputs' => { 'width' => 1024, 'image' => ['9', 0] } },
      '9' => { 'class_type' => 'LoadImage', 'inputs' => { 'image' => '{{image}}' } }
    }.freeze

    setup do
      @previous = { 'LITELLM_URL' => ENV.fetch('LITELLM_URL', nil), 'LITELLM_MODEL' => ENV.fetch('LITELLM_MODEL', nil) }
      ENV['LITELLM_URL'] = 'http://litellm.test'
      ENV['LITELLM_MODEL'] = 'gpt-test'
    end

    teardown do
      @previous.each { |key, value| ENV[key] = value }
    end

    test 'serializes one line per candidate' do
      lines = Prompt.user_message(candidates).lines(chomp: true)

      assert_equal ['node 6 | CLIPTextEncode "Mystery" | text = "line one\n\"quoted\""',
                    'node 8 | ImageScale | width = 1024'], lines
    end

    test 'truncates long values' do
      graph = { '1' => { 'class_type' => 'Lyrics', 'inputs' => { 'lyrics' => 'la ' * 200 } } }

      line = Prompt.line(Candidates.call(graph).sole)

      assert_operator line.length, :<, 240
      assert line.end_with?('..."')
    end

    test 'the prompt and schema both list the registry placeholders' do
      assert_equal Workflow::PLACEHOLDERS.keys, Prompt.schema.dig(:properties, :substitutions, :items, :properties,
                                                                  :placeholder, :enum)
      Workflow::PLACEHOLDERS.each_key { assert_includes Prompt.system_prompt, "\n- #{it}: " }

      assert_equal Workflow::PLACEHOLDERS.keys.sort, Prompt::GUIDANCE.keys.sort
    end

    test 'sends the remaining candidates with temperature 0 and a strict schema' do
      stub_replies({ substitutions: [{ node: '8', input: 'width', placeholder: 'width' }], notes: 'Resize width.' })

      outcome = LlmPass.call(candidates, GRAPH)

      assert_equal :ran, outcome.status
      assert_equal([%w[8 width width llm]],
                   outcome.substitutions.map { [it.node, it.input, it.placeholder, it.source] })
      assert_equal 'Resize width.', outcome.notes
      assert_requested(:post, COMPLETIONS) do |request|
        body = JSON.parse(request.body)

        assert_equal 0, body['temperature']
        assert_equal 'json_schema', body.dig('response_format', 'type')
        assert body.dig('response_format', 'json_schema', 'strict')
        assert_equal Prompt.system_prompt, body.dig('messages', 0, 'content')
      end
    end

    test 'retries once with the problems, then keeps what is valid' do
      stub_replies(
        { substitutions: [{ node: '8', input: 'image', placeholder: 'image' },
                          { node: '6', input: 'text', placeholder: 'resolution' }], notes: 'First.' },
        { substitutions: [{ node: '6', input: 'text', placeholder: 'prompt' },
                          { node: '7', input: 'text', placeholder: 'prompt' }], notes: 'Second.' }
      )

      outcome = LlmPass.call(candidates, GRAPH)

      assert_equal([%w[6 text prompt]], outcome.substitutions.map { [it.node, it.input, it.placeholder] })
      assert_equal ["node 7 doesn't exist"], outcome.errors
      assert_equal 'Second.', outcome.notes
      assert_requested(:post, COMPLETIONS, times: 2)
      assert_requested(:post, COMPLETIONS) do |request|
        messages = JSON.parse(request.body)['messages']
        next false unless messages.size == 4

        assert_equal %w[system user assistant user], messages.pluck('role')
        assert_includes messages.last['content'], 'node 8 input "image" is wired to another node'
        assert_includes messages.last['content'], 'placeholder "resolution" is not allowed'
      end
    end

    test 'an unreadable reply twice counts as a failure' do
      stub_request(:post, COMPLETIONS).to_return(body: completion('not json'))

      outcome = LlmPass.call(candidates, GRAPH)

      assert_equal :failed, outcome.status
      assert_empty outcome.substitutions
      assert_match(/wasn't valid JSON/, outcome.errors.first)
    end

    test 'a network failure is reported, not raised' do
      stub_request(:post, COMPLETIONS).to_raise(Errno::ECONNREFUSED)

      outcome = LlmPass.call(candidates, GRAPH)

      assert_equal :failed, outcome.status
      assert_match(/Couldn't reach LiteLLM/, outcome.failure)
    end

    private

    def candidates = Candidates.call(GRAPH).reject(&:skip?)

    def stub_replies(*replies)
      stub_request(:post, COMPLETIONS).to_return(*replies.map { { body: completion(it.to_json) } })
    end

    def completion(content) = { choices: [{ message: { content: } }] }.to_json
  end
end
