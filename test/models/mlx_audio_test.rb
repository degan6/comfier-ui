require 'test_helper'

class MlxAudioTest < ActiveSupport::TestCase
  include EngineTestHelpers

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
      end
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
