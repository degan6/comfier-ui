module LiteLlm
  # Shared Net::HTTP helpers for the LiteLLM client.
  module Http
    def post_json(uri, payload)
      http(uri).request(build_post(uri, payload))
    end

    private

    def build_post(uri, payload)
      request = Net::HTTP::Post.new(uri)
      request['Content-Type'] = 'application/json'
      request['Authorization'] = "Bearer #{Client.api_key}" if Client.api_key.present?
      request.body = JSON.generate(payload)
      request
    end

    def http(uri)
      Net::HTTP.start(uri.host, uri.port,
                      use_ssl: uri.scheme == 'https', open_timeout: 5,
                      read_timeout: Client.timeout_seconds)
    end
  end
end
