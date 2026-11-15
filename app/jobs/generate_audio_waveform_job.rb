class GenerateAudioWaveformJob < ApplicationJob
  self.enqueue_after_transaction_commit = true

  retry_on ActiveStorage::FileNotFoundError, wait: 2.seconds, attempts: 5

  def perform(blob)
    return unless blob.content_type.to_s.start_with?('audio/')

    # Concurrent viewers can request the same blob; the first worker saves it and the others reuse it.
    blob.with_lock do
      return if AudioWaveform.data(blob)&.fetch('status') == 'ready'

      save_waveform(blob)
    end
  end

  private

  def save_waveform(blob)
    value = AudioWaveform.generate(blob)
    blob.update!(metadata: blob.metadata.merge(AudioWaveform::KEY => value))
  rescue AudioWaveform::DecodeError, Errno::ENOENT => e
    Rails.logger.warn("AudioWaveform: couldn't decode blob #{blob.id}: #{e.message}")
    blob.update!(metadata: blob.metadata.merge(AudioWaveform::KEY => {
                                                 'version' => AudioWaveform::VERSION, 'status' => 'failed'
                                               }))
  end
end
