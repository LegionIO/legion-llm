# frozen_string_literal: true

require 'digest'

require 'legion/logging/helper'
module Legion
  module LLM
    module Cache
      extend Legion::Logging::Helper

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
          log.debug("LLM cache miss key=#{cache_key}")
          return nil
        end

        ::JSON.parse(raw, symbolize_names: true)
      rescue StandardError => e
        handle_exception(e, level: :warn)
        nil
      end

      # Stores a response in the cache with the given TTL.
      def set(cache_key, response, ttl: DEFAULT_TTL)
        return false unless available?

        Legion::Cache.set(cache_key, ::JSON.dump(response), ttl)
        log.debug("LLM cache write key=#{cache_key} ttl=#{ttl}")
        true
      rescue StandardError => e
        handle_exception(e, level: :warn)
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
        handle_exception(e, level: :warn)
        {}
      end
    end
  end
end
