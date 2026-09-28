# frozen_string_literal: true

module Agent
  # Shared state for agent connections, visible to the web process and Sidekiq alike: presence,
  # open job requests, hello payloads, debounce keys, and the command channel between processes.
  # Tests use the in-memory adapter so parallel workers don't share keys; the end-to-end run sets
  # AGENT_STORE=redis because its web and Sidekiq processes must share them.
  module Store
    PREFIX = 'agent:'

    class << self
      attr_writer :adapter

      def adapter
        @adapter ||= Rails.env.test? && ENV['AGENT_STORE'] != 'redis' ? MemoryAdapter.new : RedisAdapter.new
      end

      def reset! = (@adapter = nil)

      def read_json(key)
        raw = adapter.get(PREFIX + key)
        raw && JSON.parse(raw)
      rescue JSON::ParserError
        nil
      end

      def write_json(key, value, ttl: nil)
        adapter.set(PREFIX + key, JSON.generate(value), ttl:)
      end

      def delete(key) = adapter.del(PREFIX + key)

      # True the first time within `ttl` seconds; used to debounce broadcasts and recomputes.
      def once_per?(key, ttl:) = adapter.set_nx(PREFIX + key, '1', ttl:)

      # Increments a counter that expires `ttl` seconds after it was first created.
      def count_within(key, ttl:) = adapter.incr_window(PREFIX + key, ttl:)

      def publish(channel, payload) = adapter.publish(PREFIX + channel, payload)

      def subscribe(channel, &) = adapter.subscribe(PREFIX + channel, &)
    end

    class RedisAdapter
      def initialize(url: ENV.fetch('REDIS_URL', 'redis://localhost:6379/0'))
        @url = url
        @redis = Redis.new(url:)
      end

      delegate :get, to: :@redis

      def set(key, value, ttl: nil)
        ttl ? @redis.set(key, value, ex: ttl.to_i.clamp(1, nil)) : @redis.set(key, value)
      end

      delegate :del, to: :@redis

      def set_nx(key, value, ttl:) # rubocop:disable Naming/PredicateMethod
        @redis.set(key, value, nx: true, ex: ttl.to_i.clamp(1, nil)) == true
      end

      def incr_window(key, ttl:)
        count = @redis.incr(key)
        @redis.expire(key, ttl.to_i) if count == 1
        count
      end

      delegate :publish, to: :@redis

      # Blocks the calling thread; a dedicated connection is required for SUBSCRIBE.
      def subscribe(channel)
        Redis.new(url: @url).subscribe(channel) do |on|
          on.message { |_channel, payload| yield payload }
        end
      end
    end

    class MemoryAdapter
      def initialize
        @data = {}
        @subscribers = Hash.new { |hash, key| hash[key] = [] }
        @mutex = Mutex.new
      end

      def get(key)
        @mutex.synchronize do
          value, expires_at = @data[key]
          next nil if value.nil?
          next @data.delete(key) && nil if expires_at && expires_at <= now

          value
        end
      end

      def set(key, value, ttl: nil)
        @mutex.synchronize { @data[key] = [value, ttl && (now + ttl.to_f)] }
        'OK'
      end

      def del(key) = @mutex.synchronize { @data.delete(key) ? 1 : 0 }

      def set_nx(key, value, ttl:) # rubocop:disable Naming/PredicateMethod
        return false if get(key)

        set(key, value, ttl:)
        true
      end

      def incr_window(key, ttl:)
        current = get(key)
        return set(key, '1', ttl:) && 1 if current.nil?

        @mutex.synchronize do
          _, expires_at = @data[key]
          count = current.to_i + 1
          @data[key] = [count.to_s, expires_at]
          count
        end
      end

      def publish(channel, payload)
        @subscribers[channel].each { it.call(payload) }
        @subscribers[channel].size
      end

      def subscribe(channel, &block)
        @subscribers[channel] << block
      end

      private

      # Wall-clock time so ActiveSupport's travel_to moves expiry forward in tests.
      def now = Time.current.to_f
    end
  end
end
