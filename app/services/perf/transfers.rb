# frozen_string_literal: true

module Perf
  # Throughput estimates for moving bytes to and from a server, one EWMA per kind (and host for
  # model downloads).
  module Transfers
    ALPHA = 0.3
    DEFAULT_BPS = { 'input' => 20.megabytes, 'output' => 20.megabytes, 'download' => 30.megabytes }.freeze
    DEFAULT_FIXED_MS = { 'input' => 300, 'output' => 300, 'dispatch' => 500, 'download' => 2_000 }.freeze

    module_function

    def observe!(backend, kind, bytes:, ms:, host: '')
      return if ms.to_i <= 0

      stat = TransferStat.find_or_initialize_by(backend_id: backend.id, kind:, host: host.to_s)
      bps = bytes.to_i.positive? ? bytes.to_f / (ms.to_f / 1000) : nil
      stat.ewma_bps = blend(stat.ewma_bps, bps) if bps
      stat.ewma_fixed_ms = blend(stat.ewma_fixed_ms, fixed_ms(ms, bytes, stat.ewma_bps || bps))
      stat.n += 1
      stat.save!
    end

    # The part of a transfer that doesn't depend on its size.
    def fixed_ms(ms, bytes, bps)
      bytes.to_i.positive? ? [ms - ((bytes / bps) * 1000), 0].max : ms
    end

    def observe_download!(download)
      return unless download.started_at && download.bytes_total.to_i.positive?

      ms = ((download.finished_at - download.started_at) * 1000).round
      observe!(download.backend, 'download', bytes: download.bytes_total, ms:, host: URI.parse(download.url).host.to_s)
    rescue URI::InvalidURIError
      nil
    end

    def estimate_ms(backend, kind, bytes: 0, host: '')
      stat = backend && TransferStat.find_by(backend_id: backend.id, kind:, host: host.to_s)
      fixed = stat&.ewma_fixed_ms || DEFAULT_FIXED_MS.fetch(kind, 0)
      bps = stat&.ewma_bps || DEFAULT_BPS.fetch(kind, 20.megabytes)
      (fixed + (bytes.to_f / bps * 1000)).round
    end

    def download_bps(backend, host) = TransferStat.find_by(backend_id: backend.id, kind: 'download', host:)&.ewma_bps

    def blend(old, new) = old.nil? ? new.to_f : ((1 - ALPHA) * old) + (ALPHA * new.to_f)
  end
end
