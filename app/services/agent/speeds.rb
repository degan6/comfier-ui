# frozen_string_literal: true

module Agent
  # Per-server speed bookkeeping outside the hourly recompute.
  module Speeds
    module_function

    # A new server starts with the speed of another server with the same GPU.
    def inherit!(backend)
      return if backend.gpu_name.blank? || BackendSpeed.exists?(backend_id: backend.id)

      twin = BackendSpeed.joins(:backend).where(backends: { gpu_name: backend.gpu_name })
                         .where.not(backend_id: backend.id).order(n_workflows: :desc).first
      BackendSpeed.create!(backend_id: backend.id, speed_index: twin&.speed_index || 1.0)
    end

    def record_local_use!(backend, started)
      return unless started

      seconds = Time.current.to_f - started['at'].to_f
      return unless seconds.positive?

      speed = BackendSpeed.find_or_initialize_by(backend_id: backend.id)
      speed.busy_local_ewma_s = Perf::Transfers.blend(speed.busy_local_ewma_s, seconds)
      speed.save!
    end
  end
end
