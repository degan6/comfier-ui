require 'test_helper'

class GenerateAudioWaveformJobTest < ActiveJob::TestCase
  setup do
    @blob = ActiveStorage::Blob.create_and_upload!(io: StringIO.new(wav_audio), filename: 'song.wav',
                                                   content_type: 'audio/wav', metadata: { 'other' => 'keep' })
  end

  test 'saves bounded amplitude data with the audio and reuses it on later requests' do
    GenerateAudioWaveformJob.perform_now(@blob)
    data = AudioWaveform.data(@blob.reload)

    assert_equal 'ready', data['status']
    assert_in_delta 4, data['duration'], 0.01
    assert_equal 2048, data['peaks'].first.size
    assert(data['peaks'].first.all? { it.between?(0, 1) })
    assert_in_delta 6000.fdiv(32_768), data['peaks'].first.max, 0.01
    assert_equal 'keep', @blob.metadata['other']

    with_env('FFMPEG' => '/missing/ffmpeg') do
      GenerateAudioWaveformJob.perform_now(@blob)

      assert_equal data, AudioWaveform.request(@blob.reload)
    end
  end

  test 'finishing a music generation queues preparation for each audio output' do
    workflow = Workflow.create!(name: 'Music', kind: 'audio',
                                graph: { '1' => { 'class_type' => 'Music', 'inputs' => { 'text' => '{{prompt}}' } } })
    generation = users(:alice).generations.create!(workflow:, prompt: 'Two songs')
    2.times do |index|
      generation.outputs.attach(io: StringIO.new(wav_audio), filename: "song#{index}.wav", content_type: 'audio/wav')
    end

    assert_enqueued_jobs 2, only: GenerateAudioWaveformJob do
      generation.succeed!
    end
  end

  test 'requests enqueue once and a stale pending request can recover' do
    assert_enqueued_with(job: GenerateAudioWaveformJob, args: [@blob]) { AudioWaveform.request(@blob) }
    assert_no_enqueued_jobs(only: GenerateAudioWaveformJob) { AudioWaveform.request(@blob.reload) }

    travel 6.minutes do
      assert_enqueued_with(job: GenerateAudioWaveformJob) { AudioWaveform.request(@blob.reload) }
    end
  end

  test 'bad audio records failure and later views do not repeatedly decode it' do
    bad = ActiveStorage::Blob.create_and_upload!(io: StringIO.new('broken'), filename: 'bad.mp3',
                                                 content_type: 'audio/mpeg')
    GenerateAudioWaveformJob.perform_now(bad)

    assert_equal 'failed', AudioWaveform.data(bad.reload)['status']
    assert_no_enqueued_jobs(only: GenerateAudioWaveformJob) { AudioWaveform.request(bad) }
  end
end
