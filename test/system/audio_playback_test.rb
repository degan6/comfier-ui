require 'application_system_test_case'

class AudioPlaybackTest < ApplicationSystemTestCase
  setup do
    workflow = Workflow.create!(name: 'Music', kind: 'audio',
                                graph: { '1' => { 'class_type' => 'Music', 'inputs' => { 'text' => '{{prompt}}' } } })
    @generation = users(:alice).generations.create!(workflow:, prompt: 'A quiet melody')
    @generation.outputs.attach(io: StringIO.new(wav_audio), filename: 'melody.wav', content_type: 'audio/wav')
    @generation.update!(status: :succeeded)
    GenerateAudioWaveformJob.perform_now(@generation.outputs.first.blob)
    sign_in_as users(:alice)
  end

  test 'waveform plays, seeks with the keyboard, changes speed and mutes' do
    visit generation_path(@generation)

    assert_player_ready
    click_on 'Play'

    assert_button 'Pause'
    assert_eventually { evaluate_script('document.querySelector("audio").currentTime > 0') }
    click_on 'Pause'
    find('.audio-player-seek', visible: :all).send_keys(:end)

    assert_eventually { evaluate_script('document.querySelector("audio").currentTime > 3.5') }
    select '1.5×', from: 'Speed'
    click_on 'Mute'

    assert_eventually { evaluate_script('document.querySelector("audio").playbackRate === 1.5') }
    assert_selector 'button[aria-pressed="true"]', text: 'Unmute'
  end

  test 'shared and public results have the player, grids keep their compact controls' do
    @generation.share!
    @generation.create_public_link!
    visit generations_path(kind: 'audio')

    assert_selector 'audio[controls]'
    assert_no_selector '.audio-player'
    visit shared_path(@generation)

    assert_player_ready
    visit public_share_path(@generation.public_token)

    assert_player_ready
  end

  test 'Turbo navigation and a morph reconnect a working player and stop detached audio' do
    visit generation_path(@generation)

    assert_player_ready
    click_on 'Play'
    execute_script('window.oldAudio = document.querySelector("audio")')
    click_on 'Results', match: :first

    assert_eventually { evaluate_script('window.oldAudio.paused') }
    go_back

    assert_player_ready
    execute_script('window.audioMorphed = false; document.addEventListener("turbo:morph", ' \
                   '() => { window.audioMorphed = true }, { once: true }); ' \
                   'Turbo.visit(location.href, { action: "replace" })')

    assert_eventually { evaluate_script('window.audioMorphed') }
    assert_player_ready
    click_on 'Play'

    assert_button 'Pause'
    assert_eventually { evaluate_script('document.querySelector("audio").currentTime > 0') }
  end

  test 'undecodable waveforms leave the native audio controls available' do
    @generation.outputs.purge
    @generation.outputs.attach(io: StringIO.new('broken'), filename: 'broken.mp3', content_type: 'audio/mpeg')
    GenerateAudioWaveformJob.perform_now(@generation.outputs.first.blob)
    visit generation_path(@generation)

    assert_text 'Waveform unavailable. You can still use the audio player.'
    assert_selector 'audio[controls]'
    assert_no_selector '.audio-player-interface'
  end

  test 'light theme and narrow screens keep all playback controls in the page' do
    visit generation_path(@generation)

    assert_player_ready
    page.current_window.resize_to(375, 900)
    execute_script('document.documentElement.dataset.bsTheme = "light"')

    assert_button 'Play'
    assert_select 'Speed'
    assert_button 'Mute'
    assert evaluate_script(<<~JS)
      (() => {
        const player = document.querySelector('.audio-player').getBoundingClientRect();
        return [...document.querySelectorAll('.audio-player button, .audio-player select')].every(control => {
          const rect = control.getBoundingClientRect();
          return rect.left >= player.left && rect.right <= player.right;
        });
      })()
    JS
  ensure
    page.current_window.resize_to(1280, 900)
  end

  private

  def assert_player_ready
    assert_selector '.audio-player-interface', visible: true
    assert_eventually do
      evaluate_script('!!document.querySelector("[data-audio-player-target=waveform] > div")?.shadowRoot' \
                      '?.querySelector("canvas")')
    end
    assert_no_selector 'audio[controls]', visible: true
  end

  def assert_eventually(timeout: 10)
    deadline = Process.clock_gettime(Process::CLOCK_MONOTONIC) + timeout
    until yield
      flunk 'audio state did not update' if Process.clock_gettime(Process::CLOCK_MONOTONIC) > deadline
      sleep 0.1
    end
    pass
  end
end
