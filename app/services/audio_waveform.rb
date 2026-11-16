# A small, reusable amplitude envelope, stored on the audio blob rather than recalculated on each device.
class AudioWaveform
  VERSION = 1
  SAMPLE_RATE = 48_000
  POINTS = 2048
  KEY = 'audio_waveform'.freeze
  class DecodeError < StandardError; end

  def self.data(blob)
    value = blob.metadata[KEY]
    value if value && value['version'] == VERSION
  end

  # The saved data, asking for it to be prepared first when there's none. Only that first ask takes the lock, so
  # the players waiting on it are answered straight away.
  def self.request(blob)
    return data(blob) if settled?(blob)

    blob.with_lock do
      next data(blob) if settled?(blob)

      value = { 'version' => VERSION, 'status' => 'pending', 'requested_at' => Time.current.iso8601 }
      blob.update!(metadata: blob.metadata.merge(KEY => value))
      GenerateAudioWaveformJob.perform_later(blob)
      value
    end
  end

  # Ready, failed, or asked for recently enough that its job should still be on the way.
  def self.settled?(blob)
    value = data(blob)
    value.present? && (value['status'] != 'pending' || Time.iso8601(value['requested_at']) > 5.minutes.ago)
  end

  def self.generate(blob)
    blob.open do |audio|
      Tempfile.create(['waveform', '.f32']) do |pcm|
        _, error, status = Open3.capture3(
          ENV.fetch('FFMPEG', 'ffmpeg'), '-hide_banner', '-loglevel', 'error', '-y',
          '-i', audio.path, '-map', '0:a:0', '-ac', '1', '-ar', SAMPLE_RATE.to_s, '-f', 'f32le', pcm.path
        )
        raise DecodeError, error.scrub.lines.last.to_s.strip unless status.success?

        envelope(pcm)
      end
    end
  end

  def self.envelope(pcm)
    samples = pcm.size / 4
    raise DecodeError, 'No audio samples' if samples.zero?

    count = [POINTS, samples].min
    peaks = Array.new(count) do |index|
      size = ((index + 1) * samples / count) - (index * samples / count)
      [pcm.read(size * 4).unpack('e*').map(&:abs).max, 1.0].min.round(4)
    end
    { 'version' => VERSION, 'status' => 'ready', 'duration' => samples.fdiv(SAMPLE_RATE).round(3), 'peaks' => [peaks] }
  end
end
