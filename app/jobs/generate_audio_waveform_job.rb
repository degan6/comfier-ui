# Prepares an audio output's waveform (see AudioWaveform) the first time a player asks for it. Audio that can't be
# decoded is marked failed, so later views don't try again.
class GenerateAudioWaveformJob < ApplicationJob
  queue_as :default
  self.enqueue_after_transaction_commit = true

  retry_on ActiveStorage::FileNotFoundError, wait: 2.seconds, attempts: 5
  # ffmpeg isn't installed. The request stays pending, so a later view asks again once it is.
  discard_on Errno::ENOENT

  def perform(blob)
    return unless blob.content_type.to_s.start_with?('audio/')
    return if AudioWaveform.data(blob)&.fetch('status') == 'ready'

    value = waveform(blob)
    # Decoding is done by now; the lock is only held to add to whatever metadata was saved meanwhile.
    blob.with_lock { blob.update!(metadata: blob.metadata.merge(AudioWaveform::KEY => value)) }
  end

  private

  def waveform(blob)
    AudioWaveform.generate(blob)
  rescue AudioWaveform::DecodeError => e
    Rails.logger.warn("AudioWaveform: couldn't decode blob #{blob.id}: #{e.message}")
    { 'version' => AudioWaveform::VERSION, 'status' => 'failed' }
  end
end
