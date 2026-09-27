# Streams a generation output. Only allowlisted image, video, and audio types are shown inline;
# everything else (3D models included) downloads. The browser is told not to guess the type.
module OutputServing
  extend ActiveSupport::Concern
  include ActiveStorage::Streaming

  private

  def serve_output(attachment)
    blob = attachment.blob
    disposition = Agent::Outputs.inline?(blob.content_type) ? 'inline' : 'attachment'
    response.headers['X-Content-Type-Options'] = 'nosniff'
    response.headers['Content-Length'] = blob.byte_size.to_s
    response.headers['Content-Security-Policy'] = "default-src 'none'; sandbox"
    send_blob_stream blob, disposition: ActionDispatch::Http::ContentDisposition.format(
      disposition:, filename: blob.filename.sanitized
    )
  end
end
