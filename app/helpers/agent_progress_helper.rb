# Lines that say where an agent job is: waiting, downloading models, running, and why it failed.
module AgentProgressHelper
  include ServersHelper

  # "Running · 42% · about 1 min left · on studio-4090",
  # "Downloading models on studio-4090: 3.1 of 6.9 GB, about 4 min".
  def agent_progress_line(generation)
    backend = generation.backend
    case generation.agent_state
    when 'waiting_models' then models_download_line(generation, backend)
    when 'routing' then routing_line(generation)
    when 'queued' then queued_line(generation, backend)
    when 'running', 'accepted' then running_progress_line(generation, backend)
    else progress_parts(generation.agent_status_line, on_server(backend))
    end
  end

  def failure_details_for_viewer(generation)
    details = generation.error_json.presence
    return unless details && (current_user.admin? || generation.backend&.owned_by?(current_user))

    [details['exception_type'], details['node'] && "Node #{details['node']}", details['traceback_tail']]
      .compact_blank.join("\n").presence
  end

  def queued_line(generation, backend)
    return 'Waiting for a server' unless backend

    ahead = Agent::Dispatcher.ordered_queue(backend).pluck(:id).index(generation.id).to_i +
            backend.generations.agent_on_server.count
    start = generation.predicted_start_at
    start = nil unless start && start > 30.seconds.from_now
    progress_parts("Waiting for #{backend.name}", ("#{ahead} ahead" if ahead.positive?),
                   ("starts in about #{short_duration((start - Time.current) * 1000)}" if start))
  end

  def models_download_line(generation, backend)
    downloads = ModelDownload.agent_pending.where(backend_id: backend&.id)
                             .where('for_generation_ids @> ?', [generation.id].to_json).to_a
    return "Waiting for models on #{backend&.name}" if downloads.empty?

    eta = downloads.filter_map(&:agent_eta).max
    text = "Downloading models on #{backend.name}#{download_bytes_text(downloads)}"
    text += ", about #{short_duration((eta - Time.current) * 1000)}" if eta && eta > Time.current
    text
  end

  private

  def routing_line(generation)
    generation.agent_phase == 'waiting_for_server' ? Agent::Router::WAITING_FOR_OWN : 'Finding a server'
  end

  def running_progress_line(generation, backend)
    left = generation.predicted_end_at && (generation.predicted_end_at - Time.current)
    progress_parts(generation.agent_status_line, ("about #{short_duration(left * 1000)} left" if left&.positive?),
                   on_server(backend))
  end

  def download_bytes_text(downloads)
    total = downloads.sum { it.bytes_total.to_i }
    return '' unless total.positive?

    ": #{human_bytes(downloads.sum { it.bytes_done.to_i })} of #{human_bytes(total)}"
  end

  def on_server(backend) = ("on #{backend.name}" if backend)

  def progress_parts(*parts) = parts.compact_blank.join(' · ')
end
