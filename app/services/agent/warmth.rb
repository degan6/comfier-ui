# frozen_string_literal: true

module Agent
  # Whether a server still has a job's models loaded: the previous Comfier job used the same
  # model set, finished within WARM_WINDOW_S, and nothing else ran on ComfyUI in between.
  module Warmth
    module_function

    def key(backend) = "warm:#{backend.id}"

    def job_started!(backend) = Store.delete(key(backend))

    def job_finished!(backend, model_set_hash)
      return if model_set_hash.blank?

      state = { 'model_set_hash' => model_set_hash, 'at' => Time.current.to_f, 'foreign' => false }
      Store.write_json(key(backend), state, ttl: AgentTiming::WARM_WINDOW_S)
    end

    def note_status!(backend, status)
      queue = status['local_queue'] || {}
      return unless queue['foreign_running'].to_i.positive?

      state = Store.read_json(key(backend))
      Store.write_json(key(backend), state.merge('foreign' => true), ttl: AgentTiming::WARM_WINDOW_S) if state
    end

    def warm_for?(backend, model_set_hash)
      state = Store.read_json(key(backend))
      return false unless state && model_set_hash.present?

      state['model_set_hash'] == model_set_hash && !state['foreign'] &&
        Time.current.to_f - state['at'].to_f <= AgentTiming::WARM_WINDOW_S
    end

    def model_set_hash(backend) = Store.read_json(key(backend))&.dig('model_set_hash')
  end
end
