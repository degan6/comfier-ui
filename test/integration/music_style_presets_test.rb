require 'test_helper'

class MusicStylePresetsTest < ActionDispatch::IntegrationTest
  setup do
    @alice = users(:alice)
    @preset = @alice.music_style_presets.create!(name: 'Folk', description: 'Warm acoustic guitar')
    @other = users(:bob).music_style_presets.create!(name: 'Private jazz', description: 'Secret saxophone')
    sign_in_as @alice
  end

  test 'manages personal presets in settings' do
    get music_style_presets_path

    assert_response :success
    assert_select 'h2', text: 'Folk'
    assert_select 'h2', text: 'Private jazz', count: 0

    assert_difference('MusicStylePreset.count') do
      post music_style_presets_path, params: { music_style_preset: {
        name: 'Rock', description: 'Distorted guitars', user_id: users(:bob).id
      } }
    end
    assert_redirected_to music_style_presets_path
    assert_equal @alice, MusicStylePreset.find_by!(name: 'Rock').user

    patch music_style_preset_path(@preset), params: { music_style_preset: { description: 'Fingerpicked guitar' } }

    assert_equal 'Fingerpicked guitar', @preset.reload.description

    assert_difference('MusicStylePreset.count', -1) { delete music_style_preset_path(@preset) }
  end

  test 'rejects invalid and duplicate presets without losing the draft' do
    post music_style_presets_path, params: { music_style_preset: { name: 'Folk', description: 'New draft' } }

    assert_response :unprocessable_content
    assert_select 'textarea', text: 'New draft'

    patch music_style_preset_path(@preset), params: { music_style_preset: { description: '' } }

    assert_response :unprocessable_content
    assert_equal 'Warm acoustic guitar', @preset.reload.description
  end

  test 'cannot read edit or delete another users preset even as an admin' do
    [@alice, users(:admin)].each do |user|
      sign_in_as user
      get edit_music_style_preset_path(@other)

      assert_response :not_found
      patch music_style_preset_path(@other), params: { music_style_preset: { description: 'Changed' } }

      assert_response :not_found
      delete music_style_preset_path(@other)

      assert_response :not_found
    end
    assert_equal 'Secret saxophone', @other.reload.description
  end

  test 'can review an owned assistant reply as a preset but cannot import another users reply' do
    reply = chat_conversations(:alice_chat).chat_messages.create!(role: :assistant, content: 'Acoustic warmth')
    get new_music_style_preset_path(message_id: reply.id)

    assert_response :success
    assert_select 'textarea', text: 'Acoustic warmth'

    sign_in_as users(:bob)
    get new_music_style_preset_path(message_id: reply.id)

    assert_response :not_found
  end

  test 'audio studio offers only personal presets' do
    Workflow.create!(name: 'Music', kind: :audio, graph: {
                       '1' => { 'class_type' => 'Music',
                                'inputs' => { 'text' => '{{prompt}}', 'lyrics' => '{{lyrics}}' } }
                     })
    get audio_studio_path

    assert_response :success
    assert_select '#music_style_preset option', text: 'Folk'
    assert_select '#music_style_preset option', text: 'Private jazz', count: 0
  end

  test 'audio generations snapshot the style separately from song instructions and lyrics' do
    workflow = Workflow.create!(name: 'Music', kind: :audio, graph: {
                                  '1' => { 'class_type' => 'Music',
                                           'inputs' => { 'text' => '{{prompt}}', 'lyrics' => '{{lyrics}}' } }
                                })
    post generations_path, params: { generation: {
      workflow_id: workflow.id, prompt: 'A song about spring', music_style: 'Guitar and flute', lyrics: 'Hello spring'
    } }

    assert_response :redirect
    song = @alice.generations.order(:created_at).last

    assert_equal 'A song about spring', song.prompt
    assert_equal "Guitar and flute\n\nA song about spring", song.placeholder_values.fetch('prompt')
    assert_equal 'Hello spring', song.lyrics
    @preset.destroy!

    assert_equal 'Guitar and flute', song.reload.music_style
    assert_equal 'Guitar and flute', song.reusable_attributes.fetch(:music_style)

    get generation_path(song)

    assert_response :success
    assert_select 'p', text: 'Guitar and flute'
  end

  test 'clearing a reused music style stays cleared when switching workflows' do
    workflow = Workflow.create!(name: 'Music', kind: :audio, graph: {
                                  '1' => { 'class_type' => 'Music', 'inputs' => { 'text' => '{{prompt}}' } }
                                })
    song = @alice.generations.create!(workflow: workflow, prompt: 'Spring', music_style: 'Folk')
    get audio_studio_path, params: { from: song.id, carry: { prompt: 'Spring', music_style: '' } }

    assert_response :success
    assert_select 'textarea[name="generation[music_style]"]', text: ''
  end

  test 'requires sign in' do
    delete logout_path
    get music_style_presets_path

    assert_redirected_to login_path
  end
end
