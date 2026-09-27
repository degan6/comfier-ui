# frozen_string_literal: true

module Api
  module Agent
    # Input downloads and output uploads for the job an agent is running. Only the backend the job
    # is assigned to can reach it, and only while it is on that server.
    class JobsController < BaseController
      include ActiveStorage::Streaming

      INPUT_STATES = %w[dispatched accepted running].freeze
      OUTPUT_STATES = %w[accepted running uploading].freeze

      def input
        generation = scoped_generation
        return head :not_found unless generation && INPUT_STATES.include?(generation.agent_state)

        input = generation.generation_inputs.find_by(input_id: params[:input_id])
        blob = input&.blob
        return head :not_found unless blob

        response.headers['Content-Length'] = blob.byte_size.to_s
        response.headers['X-Content-Type-Options'] = 'nosniff'
        send_blob_stream blob, disposition: ActionDispatch::Http::ContentDisposition.format(
          disposition: 'attachment', filename: input.filename
        )
      end

      def outputs
        generation = scoped_generation
        return head :not_found unless generation && OUTPUT_STATES.include?(generation.agent_state)

        file = params[:file]
        problem = upload_problem(generation, file)
        return render_error(*problem) if problem

        verdict = ::Agent::Outputs.check(file.tempfile, params[:filename].presence || file.original_filename)
        return render_error(:unsupported_media_type, verdict.error) unless verdict.ok

        render json: { upload_id: store_output!(generation, file, verdict) }
      end

      private

      def upload_problem(generation, file)
        return [:bad_request, 'file is required'] unless file.respond_to?(:read) && params[:node].present?
        return [:content_too_large, 'file is too large'] if file.size > ::Agent::Outputs.max_file_bytes

        [:content_too_large, 'job outputs are too large'] if over_job_limit?(generation, file)
      end

      def scoped_generation
        id = GenerationAgent.id_from_job_id(params[:job_id])
        id && Generation.find_by(id:, backend_id: current_backend.id)
      end

      def over_job_limit?(generation, file)
        generation.generation_outputs.sum(:bytes) + file.size > ::Agent::Outputs.max_job_bytes
      end

      def store_output!(generation, file, verdict)
        upload_id = upload_id_for(generation, params[:node], verdict.filename)
        existing = GenerationOutput.find_by(upload_id:)
        return upload_id if existing&.storage_key.present?

        blob = ActiveStorage::Blob.create_and_upload!(io: file.tempfile, filename: verdict.filename,
                                                      content_type: verdict.content_type, identify: false)
        (existing || GenerationOutput.new(upload_id:)).update!(
          generation:, backend: current_backend, node: params[:node].to_s.first(64), filename: verdict.filename,
          kind: verdict.kind, mime: verdict.content_type, bytes: blob.byte_size, storage_key: blob.key
        )
        upload_id
      end

      def upload_id_for(generation, node, filename)
        "u_#{Digest::SHA256.hexdigest([generation.id, generation.agent_attempt, node, filename].join(':'))[0, 16]}"
      end

      def render_error(status, message) = render(json: { error: message }, status:)
    end
  end
end
