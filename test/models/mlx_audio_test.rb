require 'test_helper'

class MlxAudioTest < ActiveSupport::TestCase
  include EngineTestHelpers

  test 'YuE2 presets render lyrics, quality and model requirements' do
    %w[yue2-vocals yue2-instrumental].each do |preset|
      workflow = engine_workflow!(preset:, name: preset)

      assert_empty EngineRecipe.problems('mlx_audio', workflow.graph)
      Generation::QUALITIES.zip([16, 32, 48]).each do |quality, steps|
        generation = users(:alice).generations.create!(workflow:, prompt: 'Warm piano pop',
                                                       lyrics: '[Verse] Exact words', seed: 42, quality:)
        recipe = WorkflowRenderer.render(workflow.graph, generation.placeholder_values)

        assert_empty EngineRecipe.problems('mlx_audio', recipe)
        assert_equal steps, recipe['steps']
        assert_equal 180, recipe['duration']
        assert_equal '8bit', recipe['precision']
        assert_equal(preset.end_with?('-vocals') ? '[Verse] Exact words' : '[Instrumental]', recipe['lyrics'])
        assert_equal [EngineRecipe::YUE2_MODEL], workflow.recipe_models
        assert_equal 32, EngineRecipe.min_memory_gb(workflow.graph)
      end
    end
  end

  test 'YuE2 validates its own controls and supplied score' do
    recipe = EnginePreset.all.find { it.key == 'yue2-vocals' }.recipe

    assert_empty EngineRecipe.problems('mlx_audio', recipe.merge('abc' => "X:1\nK:C\nC4|", 'cfg_scale' => 1.2))
    [{ 'steps' => 65 }, { 'steps' => 1.5 }, { 'duration' => 361 }, { 'seed' => -1 },
     { 'model' => EngineRecipe::MINIMAX_MODEL }, { 'style' => '' }, { 'lyrics' => '' },
     { 'precision' => '4bit' }, { 'cot' => 'bad' }, { 'abc' => '' }, { 'abc' => 'X:1', 'cot' => 'off' },
     { 'cfg_scale' => true }, { 'cfg_scale' => '{{cfg}}' }, { 'cfg_scale' => 21 },
     { 'caption' => 'pop' }].each do |patch|
      assert_not_empty EngineRecipe.problems('mlx_audio', recipe.merge(patch)), patch.inspect
    end
  end

  test 'YuE2 presets carry the literal sampling defaults, which a recipe may leave out' do
    recipe = EnginePreset.all.find { it.key == 'yue2-vocals' }.recipe
    defaults = EngineRecipe::YUE2_SAMPLING_DEFAULTS.except('semantic_max_tokens')

    assert_equal defaults, recipe.slice(*defaults.keys)
    assert_empty EngineRecipe.problems('mlx_audio', recipe.except(*defaults.keys))
  end

  test 'YuE2 sampling rejects wrong types and values outside the native ranges' do
    recipe = EnginePreset.all.find { it.key == 'yue2-vocals' }.recipe
    invalid = { 'temperature' => [-0.1, 5.1, Float::NAN], 'top_p' => [0, 1.1, Float::INFINITY],
                'top_k' => [0, 2.5], 'repetition_penalty' => [0, -1], 'penalty_window' => [0, 101],
                'min_tokens' => [-1], 'max_tokens' => [0, 24_576] }
    %w[abc semantic].each do |stage|
      invalid.each do |control, values|
        key = "#{stage}_#{control}"

        (values + [nil, true, '{{cfg}}', '1', [], {}]).each do |value|
          assert_not_empty EngineRecipe.problems('mlx_audio', recipe.merge(key => value)), "#{key}=#{value.inspect}"
        end
      end
    end
  end

  test 'YuE2 checks token relationships and keeps omitted token limits compatible with short clips' do
    recipe = EnginePreset.all.find { it.key == 'yue2-vocals' }.recipe

    [{ 'abc_min_tokens' => 33, 'abc_max_tokens' => 32 },
     { 'semantic_min_tokens' => 101, 'semantic_max_tokens' => 100 },
     { 'semantic_max_tokens' => 4501 }, { 'semantic_min_tokens' => 4501 }].each do |patch|
      assert_not_empty EngineRecipe.problems('mlx_audio', recipe.merge(patch)), patch.inspect
    end
    bare = recipe.except(*EngineRecipe::YUE2_SAMPLING_DEFAULTS.keys)

    assert_empty EngineRecipe.problems('mlx_audio', bare.merge('duration' => 0.04))
    assert_empty EngineRecipe.problems('mlx_audio', bare.merge('semantic_max_tokens' => 100))
    assert_empty EngineRecipe.problems('mlx_audio', recipe.merge('abc_temperature' => 0, 'abc_top_p' => 1,
                                                                 'abc_min_tokens' => 0, 'abc_max_tokens' => 1))
  end

  test 'MiniMax presets render vocals or instrumentals with a useful fixed length and safe quality levels' do
    %w[minimax-music3-vocals minimax-music3-instrumental].each do |preset|
      workflow = engine_workflow!(preset:, name: preset)

      assert workflow.engine_info.allows_kind?('audio')
      assert_not workflow.engine_info.allows_kind?('image')
      Generation::QUALITIES.zip([10, 20, 30]).each do |quality, steps|
        generation = users(:alice).generations.create!(workflow:, prompt: 'A piano duet',
                                                       lyrics: "[Verse]\nExact words", seed: 2_211_510_127, quality:)
        recipe = WorkflowRenderer.render(workflow.graph, generation.placeholder_values)

        assert_equal 60, recipe['duration']
        assert_equal steps, recipe['steps']
        assert_equal 2_211_510_127, recipe['seed']
        assert_equal(preset.end_with?('-vocals') ? "[Verse]\nExact words" : '[Instrumental]', recipe['lyrics'])
        assert_equal [EngineRecipe::MINIMAX_MODEL], workflow.recipe_models
        assert_equal [1.5, 1.7, 50], recipe.values_at('semantic_guidance', 'acoustic_guidance', 'top_k')
      end
    end
  end

  test 'JSON guidance is independent of quality and the hidden generic guidance field' do
    workflow = engine_workflow!(preset: 'minimax-music3-vocals', name: 'Direct JSON controls')
    workflow.update!(guidance: 29)

    assert_not workflow.uses?(:cfg)
    %w[fast best].each do |quality|
      generation = users(:alice).generations.create!(workflow:, prompt: 'Piano duet', lyrics: '[Verse] Words',
                                                     seed: 7, quality:, cfg_level: 'strict')
      recipe = WorkflowRenderer.render(workflow.graph, generation.placeholder_values)

      assert_equal [1.5, 1.7, 50], recipe.values_at('semantic_guidance', 'acoustic_guidance', 'top_k')
      assert_nil generation.cfg
    end
  end

  test 'audio controls accept literal JSON only and older recipes keep their defaults' do
    recipe = EnginePreset.all.find { it.key == 'minimax-music3-vocals' }.recipe

    assert_empty EngineRecipe.problems('mlx_audio', recipe.except(*EngineRecipe::MINIMAX_CONTROLS.keys))
    [{ 'semantic_guidance' => '{{cfg}}' }, { 'acoustic_guidance' => '{{cfg}}' },
     { 'semantic_guidance' => -0.1 }, { 'acoustic_guidance' => 11 },
     { 'top_k' => 0 }, { 'top_k' => 16_385 }, { 'top_k' => 1.5 }, { 'top_k' => true }].each do |patch|
      assert_not_empty EngineRecipe.problems('mlx_audio', recipe.merge(patch)), patch.inspect
    end
  end

  test 'audio recipes reject unsupported models, unsafe options and out of range values' do
    recipe = EnginePreset.all.find { it.key == 'minimax-music3-vocals' }.recipe

    assert_empty EngineRecipe.problems('mlx_audio', recipe)
    [{ 'steps' => 31 }, { 'steps' => 2.5 }, { 'duration' => 301 }, { 'seed' => -1 },
     { 'model' => 'other/model' }, { 'lyrics' => '' }, { 'planning' => 'full' }].each do |patch|
      assert_not_empty EngineRecipe.problems('mlx_audio', recipe.merge(patch)), patch.inspect
    end
    assert_includes EngineRecipe.problems('mlx_audio', recipe.merge('output' => '/tmp/x.wav')),
                    '"output" is set by the agent'
  end
end
