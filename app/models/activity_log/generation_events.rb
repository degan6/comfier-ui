# Writes generation queued/finished rows on ActivityLog.
class ActivityLog
  class GenerationEvents
    def self.record_queued(generation)
      ActivityLog.record(
        kind: :generation_queued,
        user: generation.user,
        subject: generation,
        message: log_message(generation, 'Queued'),
        details: details(generation)
      )
    end

    def self.record_finished(generation)
      kind = finished_kind(generation) or return

      label = kind.to_s.delete_prefix('generation_').humanize(capitalize: false)
      ActivityLog.record(
        kind:,
        user: generation.user,
        subject: generation,
        message: log_message(generation, label),
        details: details(generation, include_outcome: true)
      )
    end

    def self.finished_kind(generation)
      return :generation_cancelled if generation.cancelled?
      return :generation_succeeded if generation.succeeded?
      return :generation_failed if generation.failed?

      nil
    end
    private_class_method :finished_kind

    def self.log_message(generation, verb)
      title = generation.title
      user_name = generation.user.display_name
      timing = timing_summary(generation)
      base = "#{user_name} · #{verb} #{generation.kind_info.label.downcase} “#{title}”"
      timing ? "#{base} (#{timing})" : base
    end
    private_class_method :log_message

    def self.timing_summary(generation)
      parts = []
      parts << "wait #{generation.queue_wait_seconds.round}s" if generation.queue_wait_seconds
      parts << "run #{generation.processing_seconds.round}s" if generation.processing_seconds
      parts << "total #{generation.run_seconds.round}s" if generation.run_seconds
      parts.join(', ').presence
    end
    private_class_method :timing_summary

    def self.details(generation, include_outcome: false)
      base = identity_details(generation).merge(timing_details(generation)).merge(text_details(generation))
      row = include_outcome ? base.merge(outcome_details(generation)) : base
      row.compact
    end
    private_class_method :details

    def self.identity_details(generation)
      {
        generation_id: generation.id,
        kind: generation.kind,
        status: generation.status,
        workflow_id: generation.workflow_id,
        workflow_name: generation.workflow_name,
        backend_id: generation.backend_id,
        backend_name: generation.backend&.name,
        comfy_prompt_id: generation.comfy_prompt_id
      }
    end
    private_class_method :identity_details

    def self.timing_details(generation)
      {
        created_at: generation.created_at&.iso8601,
        submitted_at: generation.submitted_at&.iso8601,
        completed_at: generation.completed_at&.iso8601,
        processing_started_at: generation.processing_started_at&.iso8601,
        processing_ended_at: generation.processing_ended_at&.iso8601,
        queue_wait_seconds: generation.queue_wait_seconds,
        processing_seconds: generation.processing_seconds,
        run_seconds: generation.run_seconds,
        parameters: generation.parameters
      }
    end
    private_class_method :timing_details

    def self.text_details(generation)
      { prompt: generation.prompt, negative_prompt: generation.negative_prompt, lyrics: generation.lyrics }
    end
    private_class_method :text_details

    def self.outcome_details(generation)
      { error_message: generation.error_message, output_count: generation.outputs.count }
    end
    private_class_method :outcome_details
  end
end
