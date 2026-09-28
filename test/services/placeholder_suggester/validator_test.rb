require 'test_helper'

class PlaceholderSuggester
  class ValidatorTest < ActiveSupport::TestCase
    GRAPH = {
      '3' => { 'class_type' => 'KSampler', 'inputs' => { 'seed' => 5, 'model' => ['4', 0], 'denoise' => '{{denoise}}',
                                                         'sizes' => [512, 768], 'extra' => { 'a' => 1 } } },
      '4' => { 'class_type' => 'CheckpointLoaderSimple', 'inputs' => { 'ckpt_name' => 'sd.safetensors' } },
      '5' => { 'class_type' => 'KSampler', 'inputs' => { 'seed' => 9 } }
    }.freeze

    test 'keeps valid substitutions and fills in the current value' do
      validation = validate(sub('3', 'seed', 'seed'))

      assert_empty validation.errors
      assert_equal 5, validation.valid.sole.old_value
    end

    test 'drops substitutions for missing nodes and inputs' do
      assert_equal ["node 99 doesn't exist"], validate(sub('99', 'seed', 'seed')).errors
      assert_equal ['node 3 has no input "sampler"'], validate(sub('3', 'sampler', 'seed')).errors
    end

    test 'never replaces wiring, arrays or objects' do
      errors = validate(sub('3', 'model', 'prompt'), sub('3', 'sizes', 'width'), sub('3', 'extra', 'seed')).errors

      assert_equal ['node 3 input "model" is wired to another node',
                    'node 3 input "sizes" isn\'t a single literal value',
                    'node 3 input "extra" isn\'t a single literal value'], errors
    end

    test 'drops existing placeholders and unknown placeholder names' do
      errors = validate(sub('3', 'denoise', 'denoise'), sub('3', 'seed', 'resolution')).errors

      assert_equal ['node 3 input "denoise" is already a placeholder', 'placeholder "resolution" is not allowed'],
                   errors
    end

    test 'a malicious reply aimed at a link or a skipped input gets nowhere' do
      validation = Validator.call([sub('3', 'model', 'image', 'llm'), sub('4', 'ckpt_name', 'prompt', 'llm')], GRAPH,
                                  allowed: [%w[3 seed]])

      assert_empty validation.valid
      assert_equal ['node 3 input "model" is wired to another node',
                    'node 4 input "ckpt_name" wasn\'t one of the listed inputs'], validation.errors
    end

    test 'one placeholder per input, preferring the rule' do
      validation = validate(sub('3', 'seed', 'steps', 'llm'), sub('3', 'seed', 'seed'), sub('3', 'seed', 'cfg', 'llm'))

      assert_equal([%w[3 seed seed]], validation.valid.map { [it.node, it.input, it.placeholder] })
      assert_equal 2, validation.errors.size
      assert_match(/listed more than once; kept \{\{seed\}\}/, validation.errors.first)
    end

    test 'the same placeholder may go on several inputs' do
      assert_equal 2, validate(sub('3', 'seed', 'seed'), sub('5', 'seed', 'seed')).valid.size
    end

    private

    def validate(*substitutions) = Validator.call(substitutions, GRAPH)

    def sub(node, input, placeholder, source = 'rule')
      Substitution.new(node:, input:, placeholder:, old_value: nil, source:)
    end
  end
end
