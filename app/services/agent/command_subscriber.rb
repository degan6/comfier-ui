# frozen_string_literal: true

module Agent
  # Listens for Agent::Commands published by other processes. Started lazily by the first agent
  # connection, so only processes that hold sockets subscribe.
  module CommandSubscriber
    @mutex = Mutex.new
    @started = false

    class << self
      def ensure_started!
        @mutex.synchronize do
          return if @started

          @started = true
          Store.adapter.is_a?(Store::MemoryAdapter) ? subscribe_inline : subscribe_in_thread
        end
      end

      def reset! = @mutex.synchronize { @started = false }

      private

      def subscribe_inline
        Store.subscribe(Commands::CHANNEL) { Commands.execute_payload(it) }
      end

      def subscribe_in_thread
        Thread.new do
          loop do
            Store.subscribe(Commands::CHANNEL) do |payload|
              Rails.application.executor.wrap { Commands.execute_payload(payload) }
            end
          rescue StandardError => e
            Rails.logger.error("[Agent] command subscriber: #{e.class}: #{e.message}; reconnecting")
            sleep 1
          end
        end
      end
    end
  end
end
