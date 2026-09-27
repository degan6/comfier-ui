require 'test_helper'

class PlaceholderSuggester
  class RulesTest < ActiveSupport::TestCase
    test 'ambiguous and unknown prompts, and unmatched open inputs, are left for the LLM' do
      graph = {
        '3' => { 'class_type' => 'KSampler', 'inputs' => { 'positive' => ['6', 0], 'negative' => ['6', 0] } },
        '6' => { 'class_type' => 'CLIPTextEncode', 'inputs' => { 'text' => 'shared' } },
        '7' => { 'class_type' => 'CLIPTextEncode', 'inputs' => { 'text' => 'orphan' } },
        '8' => { 'class_type' => 'ImageScale', 'inputs' => { 'width' => 1024, 'upscale_method' => 'bicubic' } },
        '9' => { 'class_type' => 'RepeatLatentBatch', 'inputs' => { 'batch_size' => 4 } }
      }

      outcome = Rules.call(Candidates.call(graph), graph)

      assert_empty outcome.substitutions
      assert_equal(%w[6.text 7.text 8.width 9.batch_size], outcome.remaining.map { "#{it.node}.#{it.input}" })
      assert_equal(['8.upscale_method'], outcome.skipped.map { "#{it.node}.#{it.input}" })
    end

    test 'denoise is left to the LLM when the latent source is unknown' do
      graph = { '3' => { 'class_type' => 'KSampler', 'inputs' => { 'denoise' => 0.5, 'steps' => 20 } } }

      outcome = Rules.call(Candidates.call(graph), graph)

      assert_equal(['3.denoise'], outcome.remaining.map { "#{it.node}.#{it.input}" })
      assert_equal ['steps'], outcome.substitutions.map(&:placeholder)
    end

    test 'CFGGuider cfg and video latent length are placed by rule' do
      graph = {
        '1' => { 'class_type' => 'CFGGuider', 'inputs' => { 'cfg' => 3.5 } },
        '2' => { 'class_type' => 'EmptyHunyuanLatentVideo', 'inputs' => { 'length' => 73, 'width' => 848 } }
      }

      substitutions = Rules.call(Candidates.call(graph), graph).substitutions

      assert_equal({ '1.cfg' => 'cfg', '2.length' => 'frames', '2.width' => 'width' },
                   substitutions.to_h { ["#{it.node}.#{it.input}", it.placeholder] })
      assert(substitutions.all? { it.source == 'rule' })
      assert_equal 73, substitutions.find { it.input == 'length' }.old_value
    end
  end
end
