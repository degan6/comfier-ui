module Backends
  # One interface over the two kinds of server, so callers don't branch on connection_kind:
  #   submit(generation), cancel(generation), refresh_inventory(backend), download(backend, requirements)
  module Runner
    module_function

    # Agent servers take every job from users who can use one; legacy backends take the rest.
    def for(generation)
      return AgentRunner.new if generation.agent_job?
      return AgentRunner.new if BackendPolicy.new(generation.user).usable_agent_backends.exists?

      LegacyRunner.new
    end

    def for_backend(backend) = backend.agent? ? AgentRunner.new : LegacyRunner.new
  end
end
