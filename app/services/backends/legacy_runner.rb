module Backends
  # ComfyUI servers the frontend calls over HTTP and polls.
  class LegacyRunner
    def submit(generation)
      backend = BackendSelector.call(generation.user, generation.workflow)
      client = backend.client
      image = upload_input_image(client, generation) if generation.input_image.attached?
      graph = WorkflowRenderer.render(generation.workflow.graph, generation.placeholder_values(image:))
      prompt_id = client.submit(graph)
      parameters = image ? generation.parameters.merge('backend_input_image' => image) : generation.parameters
      generation.update!(backend:, comfy_prompt_id: prompt_id, status: :running, submitted_at: Time.current,
                         parameters:)
      PollGenerationJob.set(wait: PollGenerationJob::INTERVAL).perform_later(generation)
    end

    def cancel(generation)
      if generation.running? && generation.backend && generation.comfy_prompt_id.present?
        generation.backend.client.cancel_prompt(generation.comfy_prompt_id)
      end
    rescue Comfyui::Error
      # Still mark it cancelled locally; polling will stop and ComfyUI may finish on its own.
    ensure
      generation.fail!(Generation::CANCELLED_MESSAGE)
    end

    def refresh_inventory(backend) = backend.refresh_inventory!

    def download(backend, requirements, **) = ModelInstaller.queue(backend, requirements)

    private

    def upload_input_image(client, generation)
      blob = generation.input_image.blob
      blob.open do |file|
        client.upload_image(file, filename: "comfier-#{generation.id}-#{blob.filename.sanitized}",
                                  content_type: blob.content_type)
      end
    end
  end
end
