require 'application_system_test_case'

class MusicStylePresetsSystemTest < ApplicationSystemTestCase
  test 'saves a chat draft and applies a personal preset without replacing the song' do
    user = users(:alice)
    Workflow.create!(name: 'Music', kind: :audio, graph: {
                       '1' => { 'class_type' => 'Music',
                                'inputs' => { 'text' => '{{prompt}}', 'lyrics' => '{{lyrics}}' } }
                     })
    Workflow.create!(name: 'Music remix', kind: :audio, graph: Workflow.find_by!(name: 'Music').graph)
    reply = chat_conversations(:alice_chat).chat_messages.create!(role: :assistant, content: 'Gentle acoustic folk')
    sign_in_as user
    visit new_music_style_preset_path(message_id: reply.id)

    assert_field 'Music style', with: 'Gentle acoustic folk'
    fill_in 'Name', with: 'My folk'
    click_on 'Save preset'

    assert_text 'Music style preset saved.'

    visit audio_studio_path
    fill_in 'Describe what you want', with: 'A song about spring'
    fill_in 'Lyrics', with: 'Hello spring'
    select 'My folk', from: 'Music style preset'

    assert_field 'Music style for this song', with: 'Gentle acoustic folk'
    assert_field 'Describe what you want', with: 'A song about spring'
    fill_in 'Music style for this song', with: 'Gentle folk with flute'
    click_on 'Music remix'

    assert_field 'Music style for this song', with: 'Gentle folk with flute'
    assert_field 'Lyrics', with: 'Hello spring'
    click_on 'Generate'

    assert_text 'Queued.'
    assert_equal 'Gentle acoustic folk', user.music_style_presets.find_by!(name: 'My folk').description
  end
end
