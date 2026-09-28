module Backends
  # Comfier Agent servers, which connect to the frontend and pull jobs.
  class AgentRunner
    def submit(generation) = Agent::Submission.enqueue!(generation)

    def cancel(generation) = Agent::JobLifecycle.cancel_by_user!(generation)

    def refresh_inventory(backend) = backend.refresh_inventory!

    def download(backend, requirements, user: nil)
      models = requirements.map { { 'folder' => it.directory, 'filename' => it.name, 'url' => it.url } }
      Agent::DownloadPlanner.manual!(backend, models, user:)
    end
  end
end
