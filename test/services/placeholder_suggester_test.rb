require 'test_helper'

class PlaceholderSuggesterTest < ActiveSupport::TestCase
  COMPLETIONS = 'http://litellm.test/v1/chat/completions'.freeze

  setup do
    @previous_url = ENV.fetch('LITELLM_URL', nil)
    @previous_model = ENV.fetch('LITELLM_MODEL', nil)
    ENV['LITELLM_URL'] = 'http://litellm.test'
    ENV['LITELLM_MODEL'] = 'gpt-test'
  end

  teardown do
    ENV['LITELLM_URL'] = @previous_url
    ENV['LITELLM_MODEL'] = @previous_model
  end

  test 'Hunyuan3D image-to-3D is handled by rules alone' do
    result = PlaceholderSuggester.call(workflow('hunyuan3d'))

    assert_equal({ '7.seed' => 'seed', '7.steps' => 'steps', '7.cfg' => 'cfg', '4.batch_size' => 'batch_size' },
                 placed(result))
    assert_equal :not_needed, result.llm.status
    assert_empty result.unclassified
    assert_not_requested :post, COMPLETIONS
  end

  test 'Hunyuan3D leaves internal settings, wiring and existing placeholders alone' do
    result = PlaceholderSuggester.call(workflow('hunyuan3d'))
    untouched = %w[7.denoise 4.resolution 8.num_chunks 8.octree_resolution 9.threshold 3.shift 10.image
                   10.filename_prefix 1.ckpt_name 2.image]

    assert_empty untouched & placed(result).keys
    assert_equal '{{image}}', result.proposed_graph.dig('2', 'inputs', 'image')
    assert_equal 4096, result.proposed_graph.dig('4', 'inputs', 'resolution')
  end

  test 'basic SD txt2img exposes everything but denoise' do
    result = PlaceholderSuggester.call(workflow('sd_txt2img'))

    assert_equal({ '3.seed' => 'seed', '3.steps' => 'steps', '3.cfg' => 'cfg', '5.width' => 'width',
                   '5.height' => 'height', '5.batch_size' => 'batch_size', '6.text' => 'prompt',
                   '7.text' => 'negative_prompt' }, placed(result))
    assert_not_requested :post, COMPLETIONS
  end

  test 'img2img exposes the image and denoise' do
    result = PlaceholderSuggester.call(workflow('img2img'))

    assert_equal 'image', placed(result)['1.image']
    assert_equal 'denoise', placed(result)['6.denoise']
    assert_equal 'prompt', placed(result)['4.text']
    assert_equal 'negative_prompt', placed(result)['5.text']
  end

  test 'conditioning through ConditioningCombine and ControlNetApplyAdvanced keeps its role' do
    result = PlaceholderSuggester.call(workflow('controlnet'))

    assert_equal 'prompt', placed(result)['2.text']
    assert_equal 'prompt', placed(result)['3.text']
    assert_equal 'negative_prompt', placed(result)['5.text']
    assert_nil placed(result)['6.strength']
  end

  test 'Flux custom sampling finds seed, steps and prompt without an LLM' do
    result = PlaceholderSuggester.call(workflow('flux'), llm: false)

    assert_equal 'seed', placed(result)['25.noise_seed']
    assert_equal 'steps', placed(result)['17.steps']
    assert_equal 'prompt', placed(result)['6.clip_l']
    assert_equal 'prompt', placed(result)['6.t5xxl']
    assert_equal 'width', placed(result)['27.width']
    assert_nil placed(result)['17.denoise']
    assert_equal :disabled, result.llm.status
    assert_equal(%w[6.guidance 26.guidance], result.unclassified.map { "#{it.node}.#{it.input}" })
  end

  test 'the LLM only sees the inputs the rules could not place' do
    stub_llm(substitutions: [{ node: '26', input: 'guidance', placeholder: 'cfg' }], notes: 'Guidance as cfg.')

    result = PlaceholderSuggester.call(workflow('flux'))

    assert_equal 'cfg', placed(result)['26.guidance']
    assert_equal 'llm', result.substitutions.find { it.node == '26' }.source
    assert_equal 'Guidance as cfg.', result.notes
    assert_empty result.unclassified
    assert_requested(:post, COMPLETIONS, times: 1) do |request|
      lines = JSON.parse(request.body).dig('messages', 1, 'content').lines(chomp: true)

      assert_equal ['node 6 | CLIPTextEncodeFlux "Prompt" | guidance = 3.5 | hint: feeds BasicGuider.conditioning',
                    'node 26 | FluxGuidance | guidance = 3.5'], lines
    end
  end

  test 'an unreachable LLM falls back to the rules and lists what is left' do
    stub_request(:post, COMPLETIONS).to_raise(Errno::ECONNREFUSED)

    result = PlaceholderSuggester.call(workflow('flux'))

    assert_equal :failed, result.llm.status
    assert_match(/Couldn't reach LiteLLM/, result.llm.failure)
    assert_equal 'seed', placed(result)['25.noise_seed']
    assert_equal 2, result.unclassified.size
  end

  test 'running on its own output finds nothing new' do
    %w[hunyuan3d sd_txt2img img2img controlnet flux].each do |name|
      first = PlaceholderSuggester.call(workflow(name), llm: false)
      second = PlaceholderSuggester.call(first.proposed_graph, llm: false)

      assert_empty second.substitutions, "#{name} changed on a second pass"
      assert_equal first.proposed_graph, second.proposed_graph
    end
  end

  test 'accepts raw JSON with bare placeholders' do
    text = '{"3": {"class_type": "KSampler", "inputs": {"seed": {{seed}}, "steps": 20, "cfg": 7}}}'

    result = PlaceholderSuggester.call(text, llm: false)

    assert_equal({ '3.steps' => 'steps', '3.cfg' => 'cfg' }, placed(result))
  end

  test 'rejects UI-format uploads with the export hint' do
    error = assert_raises(PlaceholderSuggester::Error) do
      PlaceholderSuggester.call({ 'nodes' => [], 'links' => [], 'version' => 0.4 }.to_json)
    end

    assert_equal 'This is a UI-format workflow. In ComfyUI, use Export (API) and upload that file.', error.message
  end

  test 'apply keeps only valid reviewed substitutions' do
    graph = workflow('sd_txt2img')
    reviewed = [substitution('3', 'seed', 'seed', 'manual'), substitution('3', 'model', 'prompt', 'manual')]

    applied = PlaceholderSuggester.apply(graph, reviewed)

    assert_equal '{{seed}}', applied.graph.dig('3', 'inputs', 'seed')
    assert_equal ['4', 0], applied.graph.dig('3', 'inputs', 'model')
    assert_equal ['node 3 input "model" is wired to another node'], applied.errors
    assert_equal 156_680_208_700_286, graph.dig('3', 'inputs', 'seed')
  end

  private

  def workflow(name) = JSON.parse(file_fixture("workflows/#{name}.json").read)

  def placed(result) = result.substitutions.to_h { ["#{it.node}.#{it.input}", it.placeholder] }

  def substitution(node, input, placeholder, source)
    PlaceholderSuggester::Substitution.new(node:, input:, placeholder:, old_value: nil, source:)
  end

  def stub_llm(substitutions:, notes:)
    stub_request(:post, COMPLETIONS)
      .to_return(body: { choices: [{ message: { content: { substitutions:, notes: }.to_json } }] }.to_json)
  end
end
