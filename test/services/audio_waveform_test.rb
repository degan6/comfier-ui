require 'test_helper'

class AudioWaveformTest < ActiveSupport::TestCase
  test 'a clip shorter than the envelope gets a point per sample, capped at full scale' do
    data = AudioWaveform.envelope(pcm(0.25, -0.5, 1.5))

    assert_equal 'ready', data['status']
    assert_equal [[0.25, 0.5, 1.0]], data['peaks']
  end

  test 'a longer clip keeps the loudest sample of each slice' do
    data = AudioWaveform.envelope(pcm(*[0.1, -0.8, 0.3] * AudioWaveform::POINTS))

    assert_equal [0.8] * AudioWaveform::POINTS, data['peaks'].first
    assert_in_delta (3 * AudioWaveform::POINTS).fdiv(AudioWaveform::SAMPLE_RATE), data['duration'], 0.001
  end

  test 'audio without samples is a decode error' do
    assert_raises(AudioWaveform::DecodeError) { AudioWaveform.envelope(pcm) }
  end

  private

  def pcm(*samples) = StringIO.new(samples.pack('e*'))
end
