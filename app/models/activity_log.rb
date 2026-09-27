# Append-only audit trail for sign-ins, generations, and LLM calls.
class ActivityLog < ApplicationRecord
  belongs_to :user, optional: true
  belongs_to :subject, polymorphic: true, optional: true

  enum :kind, {
    login: 'login',
    login_failed: 'login_failed',
    logout: 'logout',
    generation_queued: 'generation_queued',
    generation_succeeded: 'generation_succeeded',
    generation_failed: 'generation_failed',
    generation_cancelled: 'generation_cancelled',
    llm_chat: 'llm_chat'
  }, validate: true

  scope :recent, -> { order(created_at: :desc, id: :desc) }

  scope :search, lambda { |query|
    term = query.to_s.strip
    next all if term.blank?

    pattern = "%#{sanitize_sql_like(term)}%"
    left_joins(:user).where(
      'activity_logs.message ILIKE :q OR activity_logs.ip_address ILIKE :q OR CAST(activity_logs.details AS text) ILIKE :q ' \
      'OR users.email ILIKE :q OR users.name ILIKE :q OR users.username ILIKE :q',
      q: pattern
    ).distinct
  }

  def self.record(kind:, message:, user: nil, subject: nil, details: {}, request: nil)
    create!(
      kind:,
      user:,
      subject:,
      message: message.to_s.truncate(500),
      details: details.presence || {},
      ip_address: request&.remote_ip,
      user_agent: request&.user_agent&.truncate(1000)
    )
  rescue StandardError => e
    Rails.logger.error("ActivityLog.record failed (#{kind}): #{e.class}: #{e.message}")
    nil
  end

  def self.record_generation_queued(generation)
    record(
      kind: :generation_queued,
      user: generation.user,
      subject: generation,
      message: generation_log_message(generation, 'Queued'),
      details: generation_details(generation)
    )
  end

  def self.record_generation_finished(generation)
    kind =
      if generation.cancelled?
        :generation_cancelled
      elsif generation.succeeded?
        :generation_succeeded
      elsif generation.failed?
        :generation_failed
      else
        return
      end

    label = kind.to_s.delete_prefix('generation_').humanize(capitalize: false)
    record(
      kind:,
      user: generation.user,
      subject: generation,
      message: generation_log_message(generation, label),
      details: generation_details(generation, include_outcome: true)
    )
  end

  def self.generation_log_message(generation, verb)
    title = generation.title
    user_name = generation.user.display_name
    timing = generation_timing_summary(generation)
    base = "#{user_name} · #{verb} #{generation.kind_info.label.downcase} “#{title}”"
    timing ? "#{base} (#{timing})" : base
  end

  def self.generation_timing_summary(generation)
    parts = []
    wait = generation.queue_wait_seconds
    processing = generation.processing_seconds
    parts << "wait #{wait.round}s" if wait
    parts << "run #{processing.round}s" if processing
    parts << "total #{generation.run_seconds.round}s" if generation.run_seconds
    parts.join(', ').presence
  end

  def self.generation_details(generation, include_outcome: false)
    details = {
      generation_id: generation.id,
      kind: generation.kind,
      status: generation.status,
      workflow_id: generation.workflow_id,
      workflow_name: generation.workflow_name,
      backend_id: generation.backend_id,
      backend_name: generation.backend&.name,
      comfy_prompt_id: generation.comfy_prompt_id,
      created_at: generation.created_at&.iso8601,
      submitted_at: generation.submitted_at&.iso8601,
      completed_at: generation.completed_at&.iso8601,
      processing_started_at: generation.processing_started_at&.iso8601,
      processing_ended_at: generation.processing_ended_at&.iso8601,
      queue_wait_seconds: generation.queue_wait_seconds,
      processing_seconds: generation.processing_seconds,
      run_seconds: generation.run_seconds,
      parameters: generation.parameters,
      prompt: generation.prompt,
      negative_prompt: generation.negative_prompt,
      lyrics: generation.lyrics
    }
    if include_outcome
      details[:error_message] = generation.error_message
      details[:output_count] = generation.outputs.count
    end
    details.compact
  end

  private_class_method :generation_log_message, :generation_timing_summary, :generation_details
end
