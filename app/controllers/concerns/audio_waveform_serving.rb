module AudioWaveformServing
  private

  def serve_audio_waveform(attachment)
    return head :not_found unless attachment&.content_type.to_s.start_with?('audio/')

    data = AudioWaveform.request(attachment.blob)
    if data['status'] == 'ready'
      expires_in 1.year, private: true, immutable: true
      render json: data.slice('duration', 'peaks') if stale?(etag: [attachment.blob.key, AudioWaveform::VERSION])
    else
      waveform_pending_or_failed(data['status'])
    end
  end

  def waveform_pending_or_failed(status)
    response.headers['Cache-Control'] = 'no-store'
    render json: { status: }, status: status == 'pending' ? :accepted : :unprocessable_content
  end
end
