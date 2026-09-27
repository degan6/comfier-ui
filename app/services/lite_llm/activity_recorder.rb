module LiteLlm
  # Persists LiteLLM chat attempts on ActivityLog.
  module ActivityRecorder
    module_function

    def log(entry, endpoint:, model:)
      user = entry.audit&.user
      source = entry.audit&.source.presence || 'lite_llm'
      outcome = entry.success ? 'succeeded' : 'failed'
      ActivityLog.record(
        kind: :llm_chat,
        user:,
        message: "LLM #{source} #{outcome} (#{entry.duration_ms}ms)",
        details: {
          source:,
          model:,
          endpoint:,
          duration_ms: entry.duration_ms,
          success: entry.success,
          http_status: entry.http_status,
          error: entry.error,
          request: entry.request,
          response: entry.response_body,
          assistant_content: entry.assistant_content
        }.compact
      )
    end
  end
end
