# frozen_string_literal: true

module Agent
  # Predicted start and end times for every job on a server, in dispatch order. The running job's
  # remaining time blends its prediction with its progress; local use adds its typical duration;
  # warmness chains along the queue by model set; jobs waiting for downloads start no earlier than
  # the downloads finish, without delaying the jobs behind them.
  class Timeline
    Entry = Data.define(:generation, :start_at, :end_at, :prediction)
    DEFAULT_REMAINING_MS = 60_000

    def self.schedule(backend)
      return unless Store.once_per?("timeline:#{backend.id}", ttl: 1)

      new(backend).recompute!
    end

    def self.backlog_end(backend) = new(backend).entries.map(&:end_at).max || Time.current

    def initialize(backend)
      @backend = backend
    end

    def entries
      @entries ||= build_entries
    end

    def recompute!
      entries.each { write!(it) }
    end

    private

    # Walks the queue in order; @clock is when the server frees up, @model_set what it has loaded.
    def build_entries
      @clock = Time.current + local_use_delay
      @model_set = Warmth.model_set_hash(@backend)
      active_jobs.map { active_entry(it) } + waiting_jobs.map { waiting_entry(it) }
    end

    def active_entry(gen)
      remaining = active_remaining_ms(gen) / 1000.0
      entry = Entry.new(generation: gen, start_at: gen.running_at || gen.dispatched_at || @clock,
                        end_at: @clock + remaining, prediction: nil)
      @clock += remaining
      @model_set = gen.model_set_hash
      entry
    end

    # Jobs waiting for downloads start once the files arrive and don't hold up the jobs behind them.
    def waiting_entry(gen)
      downloading = gen.agent_state == 'waiting_models'
      prediction = Perf::Predictor.predict(gen, @backend, warm: @model_set.present? && @model_set == gen.model_set_hash)
      start = downloading ? [@clock, download_eta(gen)].max : @clock
      entry = Entry.new(generation: gen, start_at: start, end_at: start + (prediction.total_ms / 1000.0), prediction:)
      unless downloading
        @clock = entry.end_at
        @model_set = gen.model_set_hash
      end
      entry
    end

    def active_jobs = @backend.generations.agent_on_server.order(:dispatched_at).to_a

    def waiting_jobs = Dispatcher.ordered_queue(@backend, states: %w[queued waiting_models]).to_a

    def active_remaining_ms(gen)
      predicted = gen.predicted_total_ms || DEFAULT_REMAINING_MS
      progress = gen.agent_progress.to_f.clamp(0, 1)
      elapsed = gen.running_at ? (Time.current - gen.running_at) * 1000 : 0
      by_prediction = [predicted - elapsed, 0].max
      by_progress = progress.positive? ? elapsed * (1 - progress) / progress : by_prediction
      ((1 - progress) * by_prediction) + (progress * by_progress)
    end

    def local_use_delay
      return 0 unless Presence.agent_state(@backend) == 'busy_local'

      @backend.backend_speed&.busy_local_ewma_s.to_f
    end

    def download_eta(gen)
      downloads = ModelDownload.where(backend_id: @backend.id, agent_state: DownloadSender::PENDING)
                               .where('for_generation_ids @> ?', [gen.id].to_json)
      downloads.map { DownloadSender.eta(it) }.compact.max || Time.current
    end

    def write!(entry)
      gen = entry.generation
      attrs = { predicted_start_at: entry.start_at, predicted_end_at: entry.end_at }
      if entry.prediction
        attrs.merge!(predicted_total_ms: entry.prediction.total_ms, predicted_p90_ms: entry.prediction.p90_ms,
                     prediction_confidence: entry.prediction.confidence, prediction_source: entry.prediction.source,
                     warm: entry.prediction.warm)
      end
      moved = gen.predicted_end_at.nil? || (gen.predicted_end_at - entry.end_at).abs > 5
      gen.update_columns(attrs) # rubocop:disable Rails/SkipsModelValidations
      gen.broadcast_replace_later_to([gen.user, :generations]) if moved
    end
  end
end
