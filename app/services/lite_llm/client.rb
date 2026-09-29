require 'net/http'
require 'json'

module LiteLlm
  # OpenAI-compatible chat client for a LiteLLM proxy.
  class Client
    include Http
    include PromptPreprocessing

    NETWORK_ERRORS = [
      Timeout::Error, SocketError, SystemCallError, EOFError, IOError,
      OpenSSL::SSL::SSLError, Net::HTTPBadResponse, Net::ProtocolError
    ].freeze

    AuditContext = Data.define(:user, :source)
    ChatLog = Data.define(:audit, :request, :duration_ms, :success, :http_status, :response_body, :assistant_content,
                          :error)

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

    def self.preprocess_prompt(system:, user:, audit: nil) = new.preprocess_prompt(system:, user:, audit:)

    def self.complete(messages:, model: nil, audit: nil, temperature: nil, response_format: nil)
      new.complete(messages:, model:, audit:, temperature:, response_format:)
    end

    def self.models = ModelsCatalog.list

    def self.fallback_model_ids = ModelsCatalog.fallback_ids

    # `history` is earlier user/assistant turns, sent between the system prompt and `user`.
    # `json_schema` ({ name:, schema: }) asks for structured output; LiteLLM translates it for Ollama,
    # llama.cpp and LM Studio. Without it the reply is only held to being a JSON object.
    def chat(system:, user:, audit: nil, **kwargs)
      history = kwargs.fetch(:history, [])
      temperature = kwargs[:temperature]
      json_schema = kwargs[:json_schema]
      messages = [{ role: 'system', content: system }, *history, { role: 'user', content: user }]
      complete(
        messages:,
        audit:,
        temperature:,
        response_format: response_format(json_schema)
      )
    end

    def complete(messages:, model: nil, audit: nil, temperature: nil, response_format: nil)
      raise Error, 'LiteLLM is not configured (set LITELLM_URL and LITELLM_MODEL in .env)' unless self.class.configured?

      @preprocessing = false
      @audit = audit
      @model = model.presence || self.class.model
      @body = { model: @model, messages:, temperature:, response_format: }.compact
      @log_body = RequestSanitizer.sanitize(@body.stringify_keys)
      @started = Process.clock_gettime(Process::CLOCK_MONOTONIC)
      deliver_chat
    rescue *NETWORK_ERRORS => e
      record_chat(chat_log(success: false, duration_ms: elapsed_ms, error: e.message))
      raise Error, "Couldn't reach LiteLLM: #{e.message}"
    end

    private

    def deliver_chat
      response = post_json(completions_url, @body)
      duration_ms = elapsed_ms
      return handle_http_error(response, duration_ms) unless response.is_a?(Net::HTTPSuccess)

      handle_success_body(response, duration_ms)
    rescue JSON::ParserError
      record_chat(chat_log(success: false, duration_ms:, http_status: response.code, response_body: response.body,
                           error: 'Invalid JSON response'))
      raise Error, 'LiteLLM returned something that isn\'t JSON'
    end

    def handle_http_error(response, duration_ms)
      record_chat(chat_log(success: false, duration_ms:, http_status: response.code, response_body: response.body))
      raise Error, "LiteLLM returned HTTP #{response.code}"
    end

    def handle_success_body(response, duration_ms)
      parsed = JSON.parse(response.body)
      content = parsed.dig('choices', 0, 'message', 'content')
      error = response_error(parsed, content)
      record_chat(chat_log(success: error.nil?, duration_ms:, http_status: response.code, response_body: parsed,
                           assistant_content: content, error:))
      raise Error, error if error

      @preprocessing ? content.strip : content
    end

    def elapsed_ms
      ((Process.clock_gettime(Process::CLOCK_MONOTONIC) - @started) * 1000).round
    end

    def chat_log(**attrs)
      ChatLog.new(
        audit: @audit, request: @log_body,
        duration_ms: attrs.fetch(:duration_ms),
        success: attrs.fetch(:success),
        http_status: attrs[:http_status],
        response_body: attrs[:response_body],
        assistant_content: attrs[:assistant_content],
        error: attrs[:error]
      )
    end

    def response_format(json_schema)
      return { type: 'json_object' } unless json_schema

      { type: 'json_schema', json_schema: { name: json_schema.fetch(:name), strict: true,
                                            schema: json_schema.fetch(:schema) } }
    end

    def completions_url = URI("#{self.class.url}/v1/chat/completions")

    def record_chat(entry)
      ActivityRecorder.log(entry, endpoint: completions_url.to_s, model: @model)
    end
  end
end
