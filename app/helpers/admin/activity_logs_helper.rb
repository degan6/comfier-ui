module Admin
  module ActivityLogsHelper
    KIND_LABELS = {
      'login' => 'Sign in',
      'login_failed' => 'Sign-in failed',
      'logout' => 'Sign out',
      'generation_queued' => 'Generation queued',
      'generation_succeeded' => 'Generation succeeded',
      'generation_failed' => 'Generation failed',
      'generation_cancelled' => 'Generation cancelled',
      'llm_chat' => 'LLM request'
    }.freeze

    def activity_log_kind_label(kind)
      KIND_LABELS.fetch(kind.to_s, kind.to_s.humanize)
    end

    def activity_log_kind_filter_path(kind)
      params = request.query_parameters.symbolize_keys.except(:page)
      params[:kind] = kind
      admin_activity_logs_path(params)
    end

    def activity_log_kind_badge(log)
      classes = activity_log_kind_badge_classes(log.kind)
      tag.span(activity_log_kind_label(log.kind), class: classes)
    end

    def activity_log_kind_badge_classes(kind)
      base = 'badge text-11 '
      case kind
      when 'login' then "#{base}text-bg-success-subtle"
      when 'login_failed' then "#{base}text-bg-danger-subtle"
      when 'logout' then "#{base}text-bg-secondary-subtle"
      when 'generation_succeeded' then "#{base}text-bg-success-subtle"
      when 'generation_failed' then "#{base}text-bg-danger-subtle"
      when 'generation_cancelled' then "#{base}text-bg-warning-subtle"
      when 'llm_chat' then "#{base}text-bg-primary-subtle"
      else "#{base}text-bg-secondary-subtle"
      end
    end

    def activity_log_details_json(log)
      JSON.pretty_generate(log.details.as_json)
    rescue StandardError
      log.details.to_s
    end
  end
end
