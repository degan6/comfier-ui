require 'json'

module LiteLlm
  # Lists model IDs exposed by a LiteLLM proxy.
  class ModelsCatalog
    include Http

    CACHE_KEY = 'lite_llm/models'.freeze
    CACHE_TTL = 5.minutes

    def self.list = new.list

    def self.fallback_ids
      [AppSetting.current.chat_default_model, Client.model].compact_blank.uniq
    end

    def list
      return self.class.fallback_ids unless Client.configured?

      Rails.cache.fetch(CACHE_KEY, expires_in: CACHE_TTL) { fetch_ids }
    rescue Error
      self.class.fallback_ids
    end

    def fetch_ids
      response = get_json(URI("#{Client.url}/v1/models"))
      raise Error, "LiteLLM returned HTTP #{response.code}" unless response.is_a?(Net::HTTPSuccess)

      parsed = JSON.parse(response.body)
      ids = Array(parsed['data']).filter_map { |entry| entry['id'].presence }
      raise Error, 'LiteLLM returned no models' if ids.empty?

      ids.sort
    rescue JSON::ParserError
      raise Error, 'LiteLLM returned something that isn\'t JSON'
    end
  end
end
