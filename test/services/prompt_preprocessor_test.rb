require 'test_helper'

class PromptPreprocessorTest < ActiveSupport::TestCase
  setup do
    @generation = users(:alice).generations.create!(workflow: workflows(:sd_image), prompt: 'A song about tools')
  end

  test 'disabled workflows keep the original prompt without calling chat' do
    assert_equal 'A song about tools', PromptPreprocessor.call(@generation)
    assert_nil @generation.reload.parameters['preprocessed_prompt']
  end

  test 'rewrites once and preserves the original prompt and other parameters' do
    enable_preprocessing
    @generation.update!(parameters: @generation.parameters.merge('lyrics' => 'Waiting for the shop to open'))
    with_env('LITELLM_URL' => 'http://litellm.test', 'LITELLM_MODEL' => 'admin-only') do
      request = stub_request(:post, 'http://litellm.test/v1/chat/completions')
                .with do |req|
                  body = JSON.parse(req.body)
                  body['model'] == 'chat' &&
                    body.dig('messages', 1, 'content').include?('Waiting for the shop to open')
                end
                .to_return(body: { choices: [{ finish_reason: 'stop',
                                               message: { content: ' A magical tool shop ' } }] }.to_json)

      2.times { assert_equal 'A magical tool shop', PromptPreprocessor.call(@generation.reload) }
      assert_requested request, times: 1
    end
    assert_equal 'A song about tools', @generation.reload.prompt
    assert_equal 512, @generation.width
    assert_equal 'Write a visual scene.', @generation.parameters['prompt_preprocessing_system_prompt']
    assert_equal 'chat', @generation.parameters['prompt_preprocessing_model']
  end

  test 'disabled preprocessing ignores a previously stored rewrite' do
    @generation.update!(parameters: @generation.parameters.merge('preprocessed_prompt' => 'Old rewrite'))

    assert_equal @generation.prompt, PromptPreprocessor.call(@generation)
  end

  test 'preprocessing is recorded in the upstream activity log with the chat model' do
    enable_preprocessing
    with_env('LITELLM_URL' => 'http://litellm.test', 'LITELLM_MODEL' => 'admin-model') do
      stub_request(:post, 'http://litellm.test/v1/chat/completions')
        .to_return(body: { choices: [{ finish_reason: 'stop', message: { content: 'A shop' } }] }.to_json)

      PromptPreprocessor.call(@generation)
    end

    entry = ActivityLog.where(kind: :llm_chat).order(:id).last

    assert_equal 'chat', entry.details['model']
    assert_equal 'prompt_preprocessing', entry.details['source']
    assert_equal @generation.user, entry.user
    assert entry.details['success']
  end

  private

  def enable_preprocessing
    @generation.workflow.update!(prompt_preprocessing_enabled: true,
                                 prompt_preprocessing_system_prompt: 'Write a visual scene.')
  end
end
