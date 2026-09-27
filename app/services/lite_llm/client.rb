require 'net/http'
require 'json'

module LiteLlm
  # OpenAI-compatible chat client for a LiteLLM proxy.
  class Client
    NETWORK_ERRORS = [
      Timeout::Error, SocketError, SystemCallError, EOFError, IOError,
      OpenSSL::SSL::SSLError, Net::HTTPBadResponse, Net::ProtocolError
    ].freeze

    AuditContext = Data.define(:user, :source)

    def self.configured?
      url.present? && model.present?
    end

    def self.missing_config_keys
      %w[LITELLM_URL LITELLM_MODEL].select { |key| ENV.fetch(key, '').strip.empty? }
    end

    def self.url = ENV.fetch('LITELLM_URL', nil)&.strip&.chomp('/')

    def self.model = ENV.fetch('LITELLM_MODEL', nil)&.strip

    def self.api_key = ENV.fetch('LITELLM_API_KEY', nil)&.strip

    def self.timeout_seconds
      ENV.fetch('LITELLM_TIMEOUT_SECONDS', 180).to_i
    end

    def self.chat(system:, user:, audit: nil, **) = new.chat(system:, user:, audit:, **)

    # `history` is earlier user/assistant turns, sent between the system prompt and `user`.
    # `json_schema` ({ name:, schema: }) asks for structured output; LiteLLM translates it for Ollama,
    # llama.cpp and LM Studio. Without it the reply is only held to being a JSON object.
    def chat(system:, user:, audit: nil, **)
      raise Error, 'LiteLLM is not configured (set LITELLM_URL and LITELLM_MODEL in .env)' unless self.class.configured?

      body = request_body(system:, user:, **)
      started = Process.clock_gettime(Process::CLOCK_MONOTONIC)
      response = post_raw(completions_url, body)
      duration_ms = ((Process.clock_gettime(Process::CLOCK_MONOTONIC) - started) * 1000).round

      unless response.is_a?(Net::HTTPSuccess)
        log_chat(audit:, request: body, duration_ms:, success: false, http_status: response.code,
                 response_body: response.body)
        raise Error, "LiteLLM returned HTTP #{response.code}"
      end

      parsed = JSON.parse(response.body)
      content = parsed.dig('choices', 0, 'message', 'content')
      log_chat(audit:, request: body, duration_ms:, success: content.present?, http_status: response.code,
               response_body: parsed, assistant_content: content)
      raise Error, 'LiteLLM returned an empty reply' if content.blank?

      content
    rescue JSON::ParserError
      log_chat(audit:, request: body, duration_ms:, success: false, http_status: response.code,
               response_body: response.body, error: 'Invalid JSON response')
      raise Error, 'LiteLLM returned something that isn\'t JSON'
    rescue *NETWORK_ERRORS => e
      duration_ms = ((Process.clock_gettime(Process::CLOCK_MONOTONIC) - started) * 1000).round if started
      log_chat(audit:, request: body, duration_ms:, success: false, error: e.message)
      raise Error, "Couldn't reach LiteLLM: #{e.message}"
    end

    private

    def request_body(system:, user:, history: [], temperature: nil, json_schema: nil)
      {
        model: self.class.model,
        messages: [{ role: 'system', content: system }, *history, { role: 'user', content: user }],
        temperature:,
        response_format: response_format(json_schema)
      }.compact
    end

    def response_format(json_schema)
      return { type: 'json_object' } unless json_schema

      { type: 'json_schema', json_schema: { name: json_schema.fetch(:name), strict: true,
                                            schema: json_schema.fetch(:schema) } }
    end

    def completions_url
      URI("#{self.class.url}/v1/chat/completions")
    end

    def post_raw(uri, payload)
      http(uri).request(build_request(uri, payload))
    end

    def build_request(uri, payload)
      request = Net::HTTP::Post.new(uri)
      request['Content-Type'] = 'application/json'
      request['Authorization'] = "Bearer #{self.class.api_key}" if self.class.api_key.present?
      request.body = JSON.generate(payload)
      request
    end

    def http(uri)
      Net::HTTP.start(uri.host, uri.port,
                      use_ssl: uri.scheme == 'https', open_timeout: 5,
                      read_timeout: self.class.timeout_seconds)
    end

    def log_chat(audit:, request:, duration_ms:, success:, http_status: nil, response_body: nil,
                 assistant_content: nil, error: nil)
      user = audit&.user
      source = audit&.source.presence || 'lite_llm'
      outcome = success ? 'succeeded' : 'failed'
      ActivityLog.record(
        kind: :llm_chat,
        user:,
        message: "LLM #{source} #{outcome} (#{duration_ms}ms)",
        details: {
          source:,
          model: self.class.model,
          endpoint: completions_url.to_s,
          duration_ms:,
          success:,
          http_status:,
          error:,
          request:,
          response: response_body,
          assistant_content:
        }.compact
      )
    end
  end
end
