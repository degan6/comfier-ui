# frozen_string_literal: true

module Agent
  # The agent sockets held by this process. Nothing else touches sockets; other processes reach
  # them through Agent::Commands. Shared state (presence, open requests) lives in Agent::Store.
  class Hub
    REPLACEMENT_WINDOW = 5.minutes
    FLAPPING_THRESHOLD = 5

    class << self
      def instance
        @instance ||= new
      end

      def reset! = (@instance = new)
    end

    def initialize
      @mutex = Mutex.new
      @sockets = {}
    end

    # Registers the socket, closing any earlier one for the same backend with 4409.
    def connect!(backend, socket)
      previous = @mutex.synchronize do
        old = @sockets[backend.id]
        @sockets[backend.id] = socket
        old
      end
      replaced!(backend, previous) if previous && previous != socket
      socket
    end

    # Forgets the socket only if it's still the current one, so a replaced connection closing
    # late doesn't drop its replacement. Returns true when it was current.
    def disconnect!(backend_id, socket = nil)
      @mutex.synchronize do
        next false unless @sockets.key?(backend_id)
        next false if socket && @sockets[backend_id] != socket

        @sockets.delete(backend_id)
        true
      end
    end

    def local?(backend_id) = @mutex.synchronize { @sockets.key?(backend_id) }

    def socket(backend_id) = @mutex.synchronize { @sockets[backend_id] }

    def send_message(backend_id, message)
      sock = socket(backend_id)
      return false unless sock

      sock.send(JSON.generate(message))
      true
    rescue StandardError => e
      Rails.logger.warn("[Agent] send to backend #{backend_id} failed: #{e.message}")
      false
    end

    def close(backend_id, code, reason)
      sock = socket(backend_id)
      return false unless sock

      sock.close(code, reason)
      true
    rescue StandardError
      false
    end

    delegate :flapping?, to: :class

    def self.flapping?(backend)
      id = backend.respond_to?(:id) ? backend.id : backend
      Store.read_json("replacements:#{id}").to_i >= FLAPPING_THRESHOLD
    end

    private

    def replaced!(backend, previous)
      previous.close(4409, 'replaced')
      Store.count_within("replacements:#{backend.id}", ttl: REPLACEMENT_WINDOW)
    rescue StandardError
      nil
    end
  end
end
