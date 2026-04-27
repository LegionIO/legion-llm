# frozen_string_literal: true

require 'digest'

require 'legion/cache/helper'
require 'legion/logging/helper'
module Legion
  module LLM
    module Cache
      extend Legion::Logging::Helper
      extend ::Legion::Cache::Helper

      DEFAULT_TTL = 300

      module_function

      def cache_namespace = ''

      # Generates a deterministic SHA256 cache key from request parameters.
      def key(model:, provider:, messages:, temperature: nil, tools: nil, schema: nil)
        payload = Legion::JSON.dump({
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

        raw = cache_backend_get(cache_key)
        if raw.nil?
          log.debug("LLM cache miss key=#{cache_key}")
          return nil
        end

        Legion::JSON.load(raw)
      rescue StandardError => e
        handle_exception(e, level: :warn, handled: true, operation: 'llm.cache.get', key: cache_key)
        nil
      end

      # Stores a response in the cache with the given TTL.
      def set(cache_key, response, ttl: DEFAULT_TTL)
        return false unless available?

        cache_backend_set(cache_key, Legion::JSON.dump(response), ttl: ttl)
        log.debug("LLM cache write key=#{cache_key} ttl=#{ttl}")
        true
      rescue StandardError => e
        handle_exception(e, level: :warn, handled: true, operation: 'llm.cache.set', key: cache_key)
        false
      end

      # Returns true if response caching is enabled in settings and Legion::Cache is loaded.
      def enabled?
        return false unless available?

        Legion::LLM::Settings.value(:prompt_caching, :response_cache, :enabled, default: true) != false
      end

      private_class_method def self.available?
        local_cache_backend? || shared_cache_backend?
      end

      private_class_method def self.llm_settings
        Legion::LLM::Settings.current_settings
      rescue StandardError => e
        handle_exception(e, level: :warn, handled: true, operation: 'llm.cache.settings')
        {}
      end

      private_class_method def self.cache_backend_get(key)
        return local_cache_get(key) if local_cache_backend?

        cache_get(key)
      end

      private_class_method def self.cache_backend_set(key, value, ttl:)
        return local_cache_set(key, value, ttl: ttl) if local_cache_backend?

        cache_set(key, value, ttl: ttl)
      end

      private_class_method def self.local_cache_backend?
        respond_to?(:local_cache_connected?) && local_cache_connected?
      rescue StandardError
        false
      end

      private_class_method def self.shared_cache_backend?
        respond_to?(:cache_connected?) && cache_connected?
      rescue StandardError
        false
      end
    end
  end
end
