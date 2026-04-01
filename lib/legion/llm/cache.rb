# frozen_string_literal: true

require 'digest'

module Legion
  module LLM
    module Cache
      DEFAULT_TTL = 300

      module_function

      # Generates a deterministic SHA256 cache key from request parameters.
      def key(model:, provider:, messages:, temperature: nil, tools: nil, schema: nil)
        payload = ::JSON.dump({
                                model:       model.to_s,
                                provider:    provider.to_s,
                                messages:    messages,
                                temperature: temperature,
                                tools:       tools,
                                schema:      schema
                              })
        Digest::SHA256.hexdigest(payload)
      end

      # Returns the cached response hash, or nil on miss / cache unavailable.
      def get(cache_key)
        return nil unless available?

        raw = Legion::Cache.get(cache_key)
        if raw.nil?
          Legion::Logging.debug("LLM cache miss key=#{cache_key}") if defined?(Legion::Logging)
          return nil
        end

        ::JSON.parse(raw, symbolize_names: true)
      rescue StandardError => e
        Legion::Logging.warn("LLM cache get error key=#{cache_key}: #{e.message}") if defined?(Legion::Logging)
        nil
      end

      # Stores a response in the cache with the given TTL.
      def set(cache_key, response, ttl: DEFAULT_TTL)
        return false unless available?

        Legion::Cache.set(cache_key, ::JSON.dump(response), ttl)
        Legion::Logging.debug("LLM cache write key=#{cache_key} ttl=#{ttl}") if defined?(Legion::Logging)
        true
      rescue StandardError => e
        Legion::Logging.warn("LLM cache set error key=#{cache_key}: #{e.message}") if defined?(Legion::Logging)
        false
      end

      # Returns true if response caching is enabled in settings and Legion::Cache is loaded.
      def enabled?
        return false unless available?

        settings = llm_settings
        settings.dig(:prompt_caching, :response_cache, :enabled) != false
      end

      private_class_method def self.available?
        defined?(Legion::Cache) && Legion::Cache.respond_to?(:get)
      end

      private_class_method def self.llm_settings
        if Legion.const_defined?('Settings', false)
          Legion::Settings[:llm]
        else
          Legion::LLM::Settings.default
        end
      rescue StandardError => e
        Legion::Logging.warn("LLM cache settings unavailable: #{e.message}") if defined?(Legion::Logging)
        {}
      end
    end
  end
end
