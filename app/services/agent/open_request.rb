# frozen_string_literal: true

module Agent
  # The job.request an agent is waiting on, if any. Stored in Agent::Store so dispatch can run in
  # any process.
  module OpenRequest
    module_function

    def set(backend_id, request_id)
      Store.write_json(key(backend_id), { 'request_id' => request_id, 'at' => Time.current.iso8601 }, ttl: 1.hour)
    end

    def get(backend_id) = Store.read_json(key(backend_id))&.dig('request_id')

    # Status heartbeats keep an idle server's request from expiring while it stays connected.
    def refresh(backend_id)
      request_id = get(backend_id)
      set(backend_id, request_id) if request_id
    end

    def clear(backend_id) = Store.delete(key(backend_id))

    def key(backend_id) = "open_request:#{backend_id}"
  end
end
