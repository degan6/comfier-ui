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

  def self.request(blob)
    blob.with_lock do
      value = data(blob)
      return value if value && (value['status'] != 'pending' || Time.iso8601(value['requested_at']) > 5.minutes.ago)

      value = { 'version' => VERSION, 'status' => 'pending', 'requested_at' => Time.current.iso8601 }
      blob.update!(metadata: blob.metadata.merge(KEY => value))
      GenerateAudioWaveformJob.perform_later(blob)
      value
    end
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
