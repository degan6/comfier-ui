require 'test_helper'

class AudioWaveformsTest < ActionDispatch::IntegrationTest
  setup do
    @generation = generations(:alice_done)
    @generation.outputs.attach(io: StringIO.new(wav_audio), filename: 'song.wav', content_type: 'audio/wav')
    @output = @generation.outputs.last
    @data = { 'version' => 1, 'status' => 'ready', 'duration' => 4.0, 'peaks' => [[0.1, 0.2, 0.1]] }
    @output.blob.update!(metadata: @output.blob.metadata.merge(AudioWaveform::KEY => @data))
    @path = waveform_generation_path(@generation, @output)
    sign_in_as users(:alice)
  end

  test 'saved data is returned and cached with a conditional response' do
    get @path

    assert_response :success
    assert_equal @data.slice('duration', 'peaks'), response.parsed_body
    assert_includes response.headers['Cache-Control'], 'private'
    assert_includes response.headers['Cache-Control'], 'immutable'
    get @path, headers: { 'If-None-Match' => response.headers['ETag'] }

    assert_response :not_modified
  end

  test 'waveform data follows output access permissions' do
    sign_in_as users(:bob)
    get @path

    assert_response :not_found
    @generation.share!
    get @path

    assert_response :success
    get waveform_generation_path(generations(:bob_done), @output)

    assert_response :not_found
  end

  test 'public tokens serve the saved envelope and revocation removes access' do
    @generation.create_public_link!
    path = public_share_waveform_path(@generation.public_token, @generation.outputs.order(:id).index(@output))
    get path

    assert_response :success
    assert_equal @data.slice('duration', 'peaks'), response.parsed_body
    @generation.revoke_public_link!
    get path

    assert_response :not_found
  end

  test 'old audio is prepared once on demand and the pending response is not cached' do
    @output.blob.update!(metadata: {})

    assert_enqueued_with(job: GenerateAudioWaveformJob) { get @path }
    assert_response :accepted
    assert_equal 'no-store', response.headers['Cache-Control']
    assert_no_enqueued_jobs(only: GenerateAudioWaveformJob) { get @path }
  end
end
