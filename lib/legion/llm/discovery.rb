# frozen_string_literal: true

require 'legion/logging/helper'
require_relative 'discovery/ollama'
require_relative 'discovery/system'

module Legion
  module LLM
    module Discovery
      extend Legion::Logging::Helper

      @can_embed = nil
      @embedding_provider = nil
      @embedding_model = nil
      @embedding_fallback_chain = nil

      class << self
        attr_reader :embedding_provider, :embedding_model, :embedding_fallback_chain

        def can_embed?
          @can_embed == true
        end

        def run
          log.debug '[llm][discovery] run.enter'
          return unless Legion::LLM.settings.dig(:providers, :ollama, :enabled)

          Ollama.refresh!
          System.refresh!

          names = Ollama.model_names
          count = names.size
          log.info "[llm][discovery] ollama model_count=#{count} models=#{names.join(', ')}"
          log.info "[llm][discovery] system total_mb=#{System.total_memory_mb} available_mb=#{System.available_memory_mb}"
        rescue StandardError => e
          handle_exception(e, level: :warn, operation: 'llm.discovery.run')
        end

        def detect_embedding_capability
          log.debug '[llm][discovery] detect_embedding_capability.enter'
          embedding_settings = Legion::LLM.settings[:embedding] || {}
          found = find_embedding_provider(embedding_settings)
          if found
            @can_embed = true
            @embedding_provider = found[:provider]
            @embedding_model = found[:model]
            @embedding_fallback_chain = build_embedding_fallback_chain(embedding_settings)
            log.info "[llm][discovery] embedding available provider=#{@embedding_provider} model=#{@embedding_model}"
          else
            @can_embed = false
            @embedding_fallback_chain = []
            log.info '[llm][discovery] no embedding provider available'
          end
        rescue StandardError => e
          @can_embed = false
          @embedding_fallback_chain = []
          handle_exception(e, level: :warn, operation: 'llm.discovery.detect_embedding_capability')
        end

        def reset!
          log.debug '[llm][discovery] reset'
          @can_embed = nil
          @embedding_provider = nil
          @embedding_model = nil
          @embedding_fallback_chain = nil
        end

        private

        def find_embedding_provider(embedding_settings)
          fallback = embedding_settings[:provider_fallback] || %w[ollama bedrock openai]
          provider_models = embedding_settings[:provider_models] || {}
          ollama_preferred = embedding_settings[:ollama_preferred] || %w[mxbai-embed-large bge-large snowflake-arctic-embed]

          log.debug "[llm][discovery] find_embedding_provider fallback=#{fallback}"
          fallback.each do |provider_name|
            provider = provider_name.to_sym
            model = provider_models[provider_name] || provider_models[provider]
            available = probe_embedding_provider(provider, ollama_preferred)
            log.debug "[llm][discovery] find_embedding_provider provider=#{provider} available=#{available.inspect}"
            next unless available

            resolved_model = available.is_a?(String) ? available : model&.to_s
            next unless verify_embedding(provider, resolved_model)

            log.debug "[llm][discovery] find_embedding_provider result provider=#{provider} model=#{resolved_model}"
            return { provider: provider, model: resolved_model }
          end
          nil
        end

        def verify_embedding(provider, model)
          log.debug "[llm][discovery] verify_embedding provider=#{provider} model=#{model}"
          return true if provider == :ollama
          return true if provider == :azure
          return false unless provider_supports_embeddings?(provider)
          return true unless model

          start_time = Time.now
          RubyLLM.embed('health check', model: model, provider: provider)
          elapsed = ((Time.now - start_time) * 1000).round
          log.info "[llm][discovery] embedding health check ok provider=#{provider} model=#{model} elapsed_ms=#{elapsed}"
          true
        rescue StandardError => e
          handle_exception(e, level: :warn, operation: 'llm.discovery.verify_embedding', provider: provider, model: model)
          false
        end

        def probe_embedding_provider(provider, ollama_preferred)
          log.debug "[llm][discovery] probe_embedding_provider provider=#{provider}"
          case provider
          when :ollama then detect_ollama_embedding(ollama_preferred)
          else detect_cloud_embedding(provider)
          end
        end

        def detect_ollama_embedding(preferred_models)
          log.debug "[llm][discovery] detect_ollama_embedding preferred=#{preferred_models}"
          return nil unless defined?(Legion::LLM::Discovery::Ollama)
          return nil unless Legion::LLM.settings.dig(:providers, :ollama, :enabled)

          preferred_models.each do |model|
            log.debug "[llm][discovery] detect_ollama_embedding checking model=#{model}"
            return model if Ollama.model_available?(model)
          end
          nil
        rescue StandardError => e
          handle_exception(e, level: :debug, operation: 'llm.discovery.detect_ollama_embedding')
          nil
        end

        def detect_cloud_embedding(provider)
          log.debug "[llm][discovery] detect_cloud_embedding provider=#{provider}"
          provider_config = Legion::LLM.settings.dig(:providers, provider)
          return nil unless provider_config.is_a?(Hash) && provider_config[:enabled]
          return nil unless provider_supports_embeddings?(provider)

          true
        rescue StandardError => e
          handle_exception(e, level: :debug, operation: 'llm.discovery.detect_cloud_embedding', provider: provider)
          nil
        end

        def build_embedding_fallback_chain(embedding_settings)
          fallback = embedding_settings[:provider_fallback] || %w[ollama bedrock openai]
          provider_models = embedding_settings[:provider_models] || {}
          ollama_preferred = embedding_settings[:ollama_preferred] || %w[mxbai-embed-large bge-large snowflake-arctic-embed]

          log.debug "[llm][discovery] build_embedding_fallback_chain fallback=#{fallback}"
          fallback.filter_map do |provider_name|
            provider = provider_name.to_sym
            next unless provider_enabled?(provider)
            next unless provider_supports_embeddings?(provider)

            available = probe_embedding_provider(provider, ollama_preferred)
            next unless available

            model = available.is_a?(String) ? available : (provider_models[provider_name] || provider_models[provider])&.to_s
            log.debug "[llm][discovery] fallback chain entry provider=#{provider} model=#{model}"
            { provider: provider, model: model }
          end
        end

        def provider_supports_embeddings?(provider)
          provider = provider&.to_sym
          return false unless provider
          return true if %i[ollama azure].include?(provider)
          return false if provider == :anthropic

          klass = RubyLLM::Provider.resolve(provider)
          return false unless klass

          klass.instance_method(:render_embedding_payload)
          true
        rescue NameError
          false
        rescue StandardError => e
          handle_exception(e, level: :debug, operation: 'llm.discovery.provider_supports_embeddings', provider: provider)
          false
        end

        def provider_enabled?(provider)
          config = Legion::LLM.settings.dig(:providers, provider)
          config.is_a?(Hash) && config[:enabled] != false
        end
      end
    end
  end
end
