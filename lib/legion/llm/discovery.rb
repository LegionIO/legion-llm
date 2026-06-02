# frozen_string_literal: true

require 'legion/logging/helper'
require_relative 'discovery/system'
require_relative 'discovery/rule_generator'

module Legion
  module LLM
    module Discovery
      extend Legion::Logging::Helper

      @can_embed = nil
      @embedding_provider = nil
      @embedding_model = nil
      @embedding_instance = nil
      @embedding_fallback_chain = nil
      @discovered_models_cache = nil
      @discovered_models_at = nil

      EMBEDDING_TIER_ORDER = %w[local direct fleet openai_compat cloud frontier].freeze

      class << self
        attr_reader :embedding_provider, :embedding_model, :embedding_instance, :embedding_fallback_chain

        def can_embed?
          @can_embed == true
        end

        def run
          log.debug '[llm][discovery] run.enter'
          System.refresh! if discovery_enabled?

          refresh_discovered_models!
          models = discovered_models
          log.info "[llm][discovery] model_count=#{models.size} " \
                   "models=#{models.map { |m| m[:model] }.join(', ')}"
          log.info "[llm][discovery] system total_mb=#{System.total_memory_mb} " \
                   "available_mb=#{System.available_memory_mb}"
        rescue StandardError => e
          handle_exception(e, level: :warn, operation: 'llm.discovery.run')
        end

        def detect_embedding_capability
          log.debug '[llm][discovery] action=detect_embedding_capability.enter'

          if detect_embedding_from_registry
            log.debug '[llm][discovery] action=detect_embedding_capability registry_hit=true'
            return
          end

          embedding_settings = self.embedding_settings
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

        # Returns discovered instances grouped by provider for RuleGenerator compatibility.
        # Each provider maps to a hash of instance_id => { models: [...], base_url: ... }
        def discovered_instances
          models = discovered_models
          result = {}
          models.each do |m|
            provider = m[:provider]
            instance = m[:instance] || :default
            result[provider] ||= {}
            result[provider][instance] ||= { models: [] }
            result[provider][instance][:models] << normalize_model_for_rules(m)
          end
          result
        end

        # Flat list of all discovered models across all registry adapters.
        # TTL-cached; call refresh_discovered_models! to force a refresh.
        def discovered_models
          return @discovered_models_cache if @discovered_models_cache && !discovered_models_stale?

          refresh_discovered_models!
          @discovered_models_cache || []
        end

        def cached_discovered_models
          @discovered_models_cache || []
        end

        # Check whether a specific model is available from any registered provider.
        def model_available?(model, provider: nil, instance: nil)
          psym = provider&.to_sym
          isym = instance&.to_sym
          discovered_models.any? do |m|
            name_matches?(m[:model], model) &&
              (psym.nil? || m[:provider] == psym) &&
              (isym.nil? || m[:instance] == isym)
          end
        end

        # Return the size in bytes for a discovered model, or nil if unknown.
        def model_size(model, provider: nil, instance: nil)
          psym = provider&.to_sym
          isym = instance&.to_sym
          entry = discovered_models.find do |m|
            name_matches?(m[:model], model) &&
              (psym.nil? || m[:provider] == psym) &&
              (isym.nil? || m[:instance] == isym)
          end
          entry&.dig(:size_bytes)
        end

        def refresh_discovered_models!(provider: nil)
          log.debug "[llm][discovery] action=refresh_discovered_models provider=#{provider || :all}"
          return unless defined?(Call::Registry)

          if provider
            refresh_provider_models(provider)
          else
            refresh_all_provider_models
          end
        end

        # Refresh models for a single provider, preserving other providers' cached models.
        def refresh_provider_models(provider)
          return unless defined?(Call::Registry)

          fresh_models = Call::Registry.all_instances
                                       .select { |e| (e[:provider] || '').to_sym == provider }
                                       .flat_map { |entry| fetch_offering_models(entry) }

          existing = @discovered_models_cache || []
          other_models = existing.reject { |m| (m[:provider] || '').to_sym == provider }

          @discovered_models_cache = other_models + fresh_models
          @discovered_models_at = Time.now
          log.debug "[llm][discovery] action=refresh_provider_models provider=#{provider} count=#{@discovered_models_cache.size}"
        end

        def refresh_all_provider_models
          return unless defined?(Call::Registry)

          models = Call::Registry.all_instances.flat_map { |entry| fetch_offering_models(entry) }

          @discovered_models_cache = models
          @discovered_models_at = Time.now
          log.debug "[llm][discovery] action=refresh_discovered_models count=#{models.size}"
        end

        def fetch_offering_models(entry)
          adapter = entry[:adapter]
          return [] unless adapter.respond_to?(:offerings)

          begin
            Array(adapter.offerings(live: true)).map do |offering|
              data = normalize_offering(offering)
              {
                model:           (data[:id] || data[:name] || data[:model]).to_s,
                provider:        entry[:provider],
                instance:        normalize_instance_id(data[:instance_id] || data[:provider_instance] || entry[:instance]),
                tier:            data[:tier] || entry.dig(:metadata, :tier),
                size_bytes:      data[:size_bytes] || data[:size],
                capabilities:    data[:capabilities] || [],
                context_length:  data[:context_length] || data[:max_model_len] || data.dig(:limits, :context_window),
                parameter_count: data[:parameter_count] || data.dig(:metadata, :parameter_count)
              }
            end
          rescue StandardError => e
            report_discovery_failure(entry, e)
            []
          end
        end

        def reset!
          log.debug '[llm][discovery] reset'
          @can_embed = nil
          @embedding_provider = nil
          @embedding_model = nil
          @embedding_instance = nil
          @embedding_fallback_chain = nil
          @discovered_models_cache = nil
          @discovered_models_at = nil
        end

        private

        def report_discovery_failure(entry, error)
          provider = entry[:provider]
          instance = entry[:instance]
          connection_error = error.is_a?(Faraday::ConnectionFailed) ||
                             error.message.match?(/connection refused|connect.*timeout|no route to host/i)

          if connection_error
            log.warn("[llm][discovery] provider=#{provider} instance=#{instance} unreachable: #{error.message}")
          else
            handle_exception(error, level: :warn, handled: true,
                                    operation: "discovery.offerings.#{provider}/#{instance}")
          end

          return unless defined?(Router) && Router.respond_to?(:health_tracker)

          Router.health_tracker.report(
            provider: provider, instance: instance,
            signal: :error, value: 1,
            metadata: { reason: error.class.name, source: :discovery }
          )
        end

        def normalize_offering(offering)
          data = if offering.is_a?(Hash)
                   offering
                 elsif offering.respond_to?(:to_hash)
                   offering.to_hash
                 elsif offering.respond_to?(:to_h)
                   offering.to_h
                 else
                   return {}
                 end
          return {} unless data.is_a?(Hash)

          data.transform_keys { |key| key.respond_to?(:to_sym) ? key.to_sym : key }
        end

        def normalize_instance_id(value)
          return nil if value.nil?

          value.respond_to?(:to_sym) ? value.to_sym : value
        end

        def discovered_models_stale?
          return true if @discovered_models_at.nil?

          ttl = discovery_refresh_seconds
          Time.now - @discovered_models_at > ttl
        end

        def discovery_refresh_seconds
          Legion::LLM::Settings.config_value(
            Legion::LLM::Settings.config_value(llm_settings, :discovery, {}),
            :refresh_seconds, 60
          )
        end

        # Match model names allowing prefix matching for tagged variants (e.g. "llama3" matches "llama3:8b")
        def name_matches?(discovered_name, query_name)
          return false if discovered_name.nil? || query_name.nil?

          dn = discovered_name.to_s
          qn = query_name.to_s
          dn == qn || dn.start_with?("#{qn}:")
        end

        # Normalize a discovered model entry into a hash compatible with RuleGenerator
        def normalize_model_for_rules(model_entry)
          h = { 'name' => model_entry[:model] }
          h['tier'] = model_entry[:tier] if model_entry[:tier]
          h['capabilities'] = model_entry[:capabilities] if model_entry[:capabilities]&.any?
          h['context_length'] = model_entry[:context_length] if model_entry[:context_length]
          h['parameter_count'] = model_entry[:parameter_count] if model_entry[:parameter_count]
          h['size'] = model_entry[:size_bytes] if model_entry[:size_bytes]
          h
        end

        def detect_embedding_from_registry
          return false unless defined?(Call::Registry)

          embedding_instances = Call::Registry.with_capability(:embedding)
          return false if embedding_instances.empty?

          log.debug "[llm][discovery] action=detect_embedding_from_registry candidates=#{embedding_instances.size}"

          # Honor an explicitly configured embedding pin (provider and/or instance) before any
          # tier-based auto-selection, but only when the pinned instance actually has its model.
          # An empty pinned instance falls through to ranking so we never commit to a dead pin.
          selected = select_pinned_embedding_instance(embedding_instances) ||
                     select_ranked_embedding_instance(embedding_instances)

          unless selected
            log.debug '[llm][discovery] action=detect_embedding_from_registry no_usable_candidate ' \
                      '— falling through to legacy probe'
            return false
          end

          @embedding_provider = selected[:provider]
          @embedding_model    = selected[:model]
          @embedding_instance = selected[:instance]
          @can_embed          = true
          @embedding_fallback_chain = build_registry_embedding_fallback(embedding_instances)

          log.info "[llm][discovery] embedding available provider=#{@embedding_provider} " \
                   "instance=#{@embedding_instance} model=#{@embedding_model} source=registry"
          true
        rescue StandardError => e
          handle_exception(e, level: :warn, operation: 'llm.discovery.detect_embedding_from_registry')
          false
        end

        # Select the configured embedding instance when llm.embedding.instance (and optionally
        # .provider) is set and that instance is registered, embedding-capable, and actually
        # serves its resolved model. Returns { provider:, instance:, model: } or nil.
        def select_pinned_embedding_instance(embedding_instances)
          settings = embedding_settings
          pinned_instance = Legion::LLM::Settings.config_value(settings, :instance)
          pinned_provider = Legion::LLM::Settings.config_value(settings, :provider)
          return nil if pinned_instance.nil? && pinned_provider.nil?

          candidate = embedding_instances.find do |i|
            (pinned_instance.nil? || i[:instance].to_s == pinned_instance.to_s) &&
              (pinned_provider.nil? || i[:provider].to_s == pinned_provider.to_s)
          end

          unless candidate
            log.debug '[llm][discovery] action=detect_embedding_from_registry pin_not_registered ' \
                      "provider=#{pinned_provider} instance=#{pinned_instance} — ignoring pin"
            return nil
          end

          resolved = resolve_embedding_model_for(candidate)
          unless usable_embedding_instance?(candidate, resolved)
            log.debug '[llm][discovery] action=detect_embedding_from_registry pin_unusable ' \
                      "provider=#{candidate[:provider]} instance=#{candidate[:instance]} " \
                      "model=#{resolved} — ignoring pin, falling back to tier ranking"
            return nil
          end

          log.debug '[llm][discovery] action=detect_embedding_from_registry pin_honored ' \
                    "provider=#{candidate[:provider]} instance=#{candidate[:instance]} model=#{resolved}"
          { provider: candidate[:provider], instance: candidate[:instance], model: resolved }
        end

        # Walk candidates in tier order (local-first) and return the first whose resolved model is
        # actually present on that specific instance. Per-instance verification keeps the local-first
        # preference for users who genuinely run a populated local Ollama while skipping an instance
        # that merely ranks higher but does not have the model. Returns { provider:, instance:, model: }.
        def select_ranked_embedding_instance(embedding_instances)
          ranked = embedding_instances.sort_by do |i|
            EMBEDDING_TIER_ORDER.index(i.dig(:metadata, :tier).to_s) || 99
          end

          ranked.each do |candidate|
            resolved = resolve_embedding_model_for(candidate)
            next unless usable_embedding_instance?(candidate, resolved)

            return { provider: candidate[:provider], instance: candidate[:instance], model: resolved }
          end
          nil
        end

        # Resolve the embedding model for a single registry candidate using the same precedence the
        # legacy single-best path used: per-instance default_model, then the configured embedding
        # default_model, then the first embedding-capable discovered model on that instance.
        def resolve_embedding_model_for(candidate)
          candidate.dig(:metadata, :default_model) ||
            Legion::LLM::Settings.config_value(embedding_settings, :default_model) ||
            first_embedding_model_for(candidate[:provider], candidate[:instance])
        end

        # A candidate is usable only when it resolves to a model that is actually present on that
        # specific instance — guarding against committing to an empty instance (e.g. an auto-added
        # local Ollama with no embedding model pulled).
        def usable_embedding_instance?(candidate, resolved)
          return false unless resolved.to_s.length.positive?

          model_available?(resolved, provider: candidate[:provider], instance: candidate[:instance])
        end

        def build_registry_embedding_fallback(instances)
          instances.sort_by { |i| EMBEDDING_TIER_ORDER.index(i.dig(:metadata, :tier).to_s) || 99 }
                   .map do |i|
            {
              provider: i[:provider],
              model:    i.dig(:metadata, :default_model),
              instance: i[:instance]
            }
          end
        end

        def first_embedding_model_for(provider, instance)
          embedding_caps = %w[embedding embeddings embed].freeze
          cached_discovered_models.find do |m|
            m[:provider].to_s == provider.to_s && m[:instance].to_s == instance.to_s &&
              Array(m[:capabilities]).any? { |c| embedding_caps.include?(c.to_s) }
          end&.dig(:model)
        end

        def find_embedding_provider(embedding_settings)
          fallback = Legion::LLM::Settings.config_value(embedding_settings, :provider_fallback, %w[ollama bedrock openai])
          provider_models = Legion::LLM::Settings.config_value(embedding_settings, :provider_models, {})
          ollama_preferred = Legion::LLM::Settings.config_value(embedding_settings, :ollama_preferred,
                                                                %w[mxbai-embed-large bge-large snowflake-arctic-embed])

          log.debug "[llm][discovery] find_embedding_provider fallback=#{fallback}"
          fallback.each do |provider_name|
            provider = provider_name.to_sym
            model = Legion::LLM::Settings.config_value(provider_models, provider_name)
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
          return true unless model

          model_available?(model, provider: provider)
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
          return nil unless provider_enabled?(:ollama)

          preferred_models.each do |m|
            log.debug "[llm][discovery] detect_ollama_embedding checking model=#{m}"
            return m if model_available?(m, provider: :ollama)
          end
          nil
        rescue StandardError => e
          handle_exception(e, level: :warn, operation: 'llm.discovery.detect_ollama_embedding')
          nil
        end

        def detect_cloud_embedding(provider)
          log.debug "[llm][discovery] detect_cloud_embedding provider=#{provider}"
          provider_config = Legion::LLM::Settings.config_value(providers_settings, provider)
          return nil unless provider_config.is_a?(Hash) && Legion::LLM::Settings.config_value(provider_config, :enabled)
          return nil unless provider_supports_embeddings?(provider)

          true
        rescue StandardError => e
          handle_exception(e, level: :warn, operation: 'llm.discovery.detect_cloud_embedding', provider: provider)
          nil
        end

        def build_embedding_fallback_chain(embedding_settings)
          fallback = Legion::LLM::Settings.config_value(embedding_settings, :provider_fallback, %w[ollama bedrock openai])
          provider_models = Legion::LLM::Settings.config_value(embedding_settings, :provider_models, {})
          ollama_preferred = Legion::LLM::Settings.config_value(embedding_settings, :ollama_preferred,
                                                                %w[mxbai-embed-large bge-large snowflake-arctic-embed])

          log.debug "[llm][discovery] build_embedding_fallback_chain fallback=#{fallback}"
          fallback.filter_map do |provider_name|
            provider = provider_name.to_sym
            next unless provider_enabled?(provider)
            next unless provider_supports_embeddings?(provider)

            available = probe_embedding_provider(provider, ollama_preferred)
            next unless available

            model = available.is_a?(String) ? available : Legion::LLM::Settings.config_value(provider_models, provider_name)&.to_s
            log.debug "[llm][discovery] fallback chain entry provider=#{provider} model=#{model}"
            { provider: provider, model: model }
          end
        end

        def provider_supports_embeddings?(provider)
          provider = provider&.to_sym
          return false unless provider
          return true if %i[ollama azure].include?(provider)
          return false if provider == :anthropic

          adapter = Call::Registry.for(provider)
          return true if adapter.respond_to?(:embed)

          %i[openai bedrock gemini vertex azure_foundry vllm mlx].include?(provider)
        rescue StandardError => e
          handle_exception(e, level: :warn, operation: 'llm.discovery.provider_supports_embeddings', provider: provider)
          false
        end

        def provider_enabled?(provider)
          config = Legion::LLM::Settings.config_value(providers_settings, provider)
          config.is_a?(Hash) && Legion::LLM::Settings.config_value(config, :enabled) != false
        end

        def embedding_settings
          settings = llm_settings
          result = Legion::LLM::Settings.config_value(settings, :embedding)
          return result if result.is_a?(Hash) && !result.empty?

          plural = Legion::LLM::Settings.config_value(settings, :embeddings)
          if plural.is_a?(Hash) && !plural.empty?
            log.warn '[llm][discovery] settings key "embeddings" (plural) is deprecated — rename to "embedding" (singular)'
            return plural
          end

          result || {}
        end

        def providers_settings
          ext = Legion::Settings[:extensions]
          return ext[:llm] if ext.is_a?(Hash) && ext[:llm].is_a?(Hash)

          {}
        rescue StandardError => e
          handle_exception(e, level: :warn, handled: true, operation: 'llm.discovery.providers_settings')
          {}
        end

        def llm_settings
          Legion::LLM::Settings.current_settings
        rescue StandardError => e
          handle_exception(e, level: :warn, operation: 'llm.discovery.settings')
          {}
        end

        def discovery_enabled?
          Legion::LLM::Settings.config_value(Legion::LLM::Settings.config_value(llm_settings, :discovery, {}), :enabled) != false
        end
      end
    end
  end
end
