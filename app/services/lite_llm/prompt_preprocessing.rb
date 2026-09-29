module LiteLlm
  # Plain-text generation shares the client's HTTP handling and activity audit trail.
  module PromptPreprocessing
    def preprocess_prompt(system:, user:, audit: nil)
      raise Error, 'LiteLLM is not configured (set LITELLM_URL)' if Client.url.blank?

      @preprocessing = true
      @audit = audit
      @body = {
        model: 'chat', messages: [{ role: 'system', content: system }, { role: 'user', content: user }],
        max_tokens: 512, extra_body: { chat_template_kwargs: { enable_thinking: false } }
      }
      @started = Process.clock_gettime(Process::CLOCK_MONOTONIC)
      deliver_chat
    rescue *Client::NETWORK_ERRORS => e
      record_chat(chat_log(success: false, duration_ms: elapsed_ms, error: e.message))
      raise Error, "Couldn't reach LiteLLM: #{e.message}"
    end

    private

    def response_error(parsed, content)
      if @preprocessing && parsed.dig('choices', 0, 'finish_reason') != 'stop'
        return 'Chat did not return a complete prompt'
      end
      return 'LiteLLM returned an empty reply' unless content.is_a?(String) && content.strip.present?

      nil
    end
  end
end
