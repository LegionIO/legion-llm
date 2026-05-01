# frozen_string_literal: true

require 'legion/logging/helper'

module Legion
  module LLM
    module Inventory
      extend Legion::Logging::Helper

      DEFAULT_PROVIDER_TIERS = {
        ollama:    :local,
        vllm:      :fleet,
        mlx:       :local,
        bedrock:   :cloud,
        azure:     :cloud,
        gemini:    :cloud,
        anthropic: :frontier,
        openai:    :frontier
      }.freeze

      DEFAULT_PROVIDER_TRANSPORTS = {
        ollama:    :http,
        vllm:      :http,
        mlx:       :http,
        bedrock:   :sdk,
        azure:     :http,
        gemini:    :http,
        anthropic: :http,
        openai:    :http
      }.freeze

      DEFAULT_CAPABILITIES = {
        embed:     %i[embed],
        inference: %i[chat completion tools json_schema],
        chat:      %i[chat completion tools json_schema]
      }.freeze

      class << self
        def offerings(filters = {})
          log.debug "[llm][inventory] action=offerings.enter filters=#{filters.keys}"
          normalized_filters = normalize_filter_hash(filters)
          list = []
          providers_config.each do |provider_family, config|
            next unless enabled_config?(config)

            list.concat(provider_offerings(provider_family.to_sym, config))
          end

          list.concat(discovery_offerings)
          list.concat(native_provider_offerings)
          list = dedupe_offerings(list)
          result = filter_offerings(list, normalized_filters)
          log.debug "[llm][inventory] action=offerings.complete total=#{result.size}"
          result
        rescue NameError, ArgumentError, TypeError => e
          handle_exception(e, level: :error, handled: false, operation: 'llm.inventory.offerings')
          raise
        rescue StandardError => e
          handle_exception(e, level: :warn, handled: true, operation: 'llm.inventory.offerings')
          []
        end

        def providers
          offerings.group_by { |offering| offering[:provider_family] }
        end

        private

        def providers_config
          ext = Legion::Settings[:extensions]
          return ext[:llm] if ext.is_a?(Hash) && ext[:llm].is_a?(Hash)

          {}
        rescue StandardError => e
          handle_exception(e, level: :warn, handled: true, operation: 'llm.inventory.providers_config')
          {}
        end

        def embedding_settings
          Legion::LLM::Settings.value(:embedding, default: {})
        end

        def enabled_config?(config)
          config.is_a?(Hash) && option(config, :enabled) != false
        end

        def provider_offerings(provider_family, config)
          list = []
          list.concat(configured_provider_offerings(provider_family, config))
          list.concat(default_provider_offerings(provider_family, config))
          list.concat(instance_offerings(provider_family, config))
          list
        end

        def configured_provider_offerings(provider_family, config)
          raw = configured_entries(option(config, :offerings) || option(config, :models))
          raw.filter_map do |entry|
            build_offering(provider_family, config, normalize_model_entry(entry))
          end
        end

        def configured_entries(entries)
          case entries
          when Hash
            entries.map { |model, entry| entry.is_a?(Hash) ? entry.merge(model: model) : { model: entry } }
          else
            Array(entries)
          end
        end

        def default_provider_offerings(provider_family, config)
          list = []
          default_model = option(config, :default_model)
          list << build_offering(provider_family, config, model: default_model, type: :inference, source: :settings_default) if default_model

          provider_models = option(embedding_settings, :provider_models, {})
          embed_model = provider_models[provider_family] || provider_models[provider_family.to_s]
          list << build_offering(provider_family, config, model: embed_model, type: :embed, source: :settings_embedding) if embed_model

          list.compact
        end

        def instance_offerings(provider_family, provider_config)
          instances = option(provider_config, :instances)
          return [] unless instances.respond_to?(:each)

          instances.flat_map do |instance_id, instance_config|
            next [] unless enabled_config?(instance_config)

            instance_base = provider_config.merge(instance_config)
            configured_entries(option(instance_base, :offerings) || option(instance_base, :models)).filter_map do |entry|
              normalized = normalize_model_entry(entry).merge(instance_id: instance_id)
              build_offering(provider_family, instance_base, normalized)
            end
          end
        end

        def normalize_model_entry(entry)
          case entry
          when Hash
            normalize_hash(entry)
          else
            { model: entry }
          end
        end

        def build_offering(provider_family, config, entry)
          model = (option(entry, :model) || option(entry, :id) || option(entry, :name)).to_s
          return nil if model.empty?

          type = normalize_type(option(entry, :usage_type) || option(entry, :type) || option(entry, :purpose) ||
                                option(entry, :kind) || infer_model_type(model))
          limits = normalize_limits(option(entry, :limits) || entry)
          source = (option(entry, :source) || :settings).to_sym
          metadata = normalize_hash(option(entry, :metadata) || option(config, :metadata) || {})
          model_family = normalize_symbol(option(entry, :model_family) || metadata[:model_family] || provider_family)
          canonical_model_alias = option(entry, :canonical_model_alias) || metadata[:canonical_model_alias] ||
                                  metadata[:alias] || model
          routing_metadata = normalize_hash(option(entry, :routing_metadata) || metadata[:routing_metadata] || {})
          provider_instance = (option(entry, :provider_instance) || option(entry, :instance_id) ||
                               option(config, :provider_instance) || option(config, :instance_id) ||
                               provider_family).to_s
          resolved_offering_id = (option(entry, :offering_id) ||
                                  offering_id(provider_family, provider_instance, canonical_model_alias || model, type)).to_s

          offering = {
            id:                    resolved_offering_id,
            offering_id:           resolved_offering_id,
            model:                 model,
            model_family:          model_family&.to_s,
            canonical_model_alias: canonical_model_alias&.to_s,
            type:                  type,
            provider_family:       provider_family.to_s,
            provider_instance:     provider_instance,
            instance_id:           provider_instance,
            tier:                  normalize_symbol(option(entry, :tier) || option(config, :tier) || DEFAULT_PROVIDER_TIERS[provider_family]),
            transport:             normalize_symbol(option(entry, :transport) || option(config, :transport) ||
                                                DEFAULT_PROVIDER_TRANSPORTS[provider_family]),
            enabled:               option(entry, :enabled, true),
            capabilities:          normalize_capabilities(option(entry, :capabilities), type),
            limits:                limits,
            health:                provider_health(provider_family, resolved_offering_id),
            cost:                  option(entry, :cost) || {},
            policy_tags:           Array(option(entry, :policy_tags) || option(config, :policy_tags)).map(&:to_s),
            metadata:              metadata,
            routing_metadata:      routing_metadata,
            source:                source.to_s
          }.compact

          add_fleet_lane(offering)
        end

        def offering_id(provider_family, instance_id, model, type)
          parts = [provider_family, instance_id, type, model].compact.map(&:to_s)
          parts.join(':')
        end

        def normalize_limits(entry)
          entry = normalize_hash(entry)
          limits = {}
          context = entry[:context_window] || entry[:max_context_size] || entry[:max_input_tokens]
          output = entry[:max_output_tokens] || entry[:output_tokens]
          limits[:context_window] = integer_or_nil(context) if context
          limits[:max_output_tokens] = integer_or_nil(output) if output
          limits[:rpm] = integer_or_nil(entry[:rpm]) if entry[:rpm]
          limits[:tpm] = integer_or_nil(entry[:tpm]) if entry[:tpm]
          limits.compact
        end

        def normalize_capabilities(capabilities, type)
          raw = capabilities || DEFAULT_CAPABILITIES.fetch(type, DEFAULT_CAPABILITIES[:inference])
          Array(raw).map(&:to_s).uniq.sort
        end

        def normalize_type(value)
          case value.to_s
          when 'embedding', 'embeddings', 'embed'
            :embed
          else
            :inference
          end
        end

        def infer_model_type(model)
          model.to_s.downcase.include?('embed') ? :embed : :inference
        end

        def normalize_symbol(value)
          value&.to_s&.to_sym
        end

        def integer_or_nil(value)
          Integer(value)
        rescue ArgumentError, TypeError => e
          handle_exception(e, level: :warn, handled: true, operation: 'llm.inventory.integer_or_nil', value: value)
          nil
        end

        def provider_health(provider_family, offering_id = nil)
          if defined?(Legion::LLM::Router) && Legion::LLM::Router.respond_to?(:routing_enabled?) &&
             Legion::LLM::Router.routing_enabled?
            tracker = Legion::LLM::Router.health_tracker
            { circuit_state: tracker.circuit_state(provider_family, offering_id: offering_id).to_s,
              adjustment:    tracker.adjustment(provider_family, offering_id: offering_id) }
          else
            { circuit_state: 'unknown' }
          end
        end

        def add_fleet_lane(offering)
          return offering unless defined?(Legion::LLM::Fleet::Lane)

          context_window = offering.dig(:limits, :context_window)
          offering.merge(fleet_lane: Legion::LLM::Fleet::Lane.routing_key(
            operation:      offering[:type],
            model:          offering[:model],
            context_window: context_window
          ), fleet_offering_lane: Legion::LLM::Fleet::Lane.offering_key(
            instance_id: offering[:provider_instance],
            model:       offering[:model],
            operation:   offering[:type]
          ))
        end

        def discovery_offerings
          ollama_discovery_offerings + vllm_discovery_offerings
        end

        def native_provider_offerings
          return [] unless defined?(Legion::LLM::Call::Registry)

          Legion::LLM::Call::Registry.available.flat_map do |provider_name|
            adapter = Legion::LLM::Call::Registry.for(provider_name)
            next [] unless adapter.respond_to?(:offerings)

            Array(adapter.offerings).filter_map do |offering|
              normalize_native_offering(provider_name, offering)
            end
          rescue StandardError => e
            handle_exception(e, level: :warn, handled: true, operation: 'llm.inventory.native_provider',
                                provider: provider_name)
            []
          end
        end

        def normalize_native_offering(provider_name, offering)
          data = normalize_hash(offering.respond_to?(:to_h) ? offering.to_h : offering)
          provider_family = normalize_symbol(option(data, :provider_family) || option(data, :provider) || provider_name)
          usage_type = option(data, :usage_type)
          entry = data.merge(
            model:    option(data, :model),
            type:     normalize_type(usage_type || option(data, :type)),
            source:   :native_provider,
            metadata: normalize_hash(option(data, :metadata))
          )
          build_offering(provider_family, {}, entry)
        end

        def ollama_discovery_offerings
          return [] unless defined?(Legion::LLM::Discovery::Ollama)

          config = option(providers_config, :ollama, {})
          return [] unless enabled_config?(config)

          Legion::LLM::Discovery::Ollama.models.filter_map do |model|
            model_name = model['name'] || model[:name]
            build_offering(:ollama, config, model: model_name, type: infer_model_type(model_name), source: :discovery)
          end
        rescue StandardError => e
          handle_exception(e, level: :warn, handled: true, operation: 'llm.inventory.discovery.ollama')
          []
        end

        def vllm_discovery_offerings
          return [] unless defined?(Legion::LLM::Discovery::Vllm)

          config = option(providers_config, :vllm, {})
          return [] unless enabled_config?(config)

          Legion::LLM::Discovery::Vllm.models.filter_map do |model|
            model_id = model[:id] || model['id']
            context_window = model[:max_model_len] || model['max_model_len']
            build_offering(:vllm, config,
                           model:          model_id,
                           type:           :inference,
                           context_window: context_window,
                           source:         :discovery)
          end
        rescue StandardError => e
          handle_exception(e, level: :warn, handled: true, operation: 'llm.inventory.discovery.vllm')
          []
        end

        def option(hash, key, default = nil)
          return default unless hash.respond_to?(:key?)

          string_key = key.to_s
          return hash[string_key] if hash.key?(string_key)

          hash.key?(key) ? hash[key] : default
        end

        def normalize_hash(hash)
          return {} unless hash.is_a?(Hash)

          hash.each_with_object({}) do |(key, value), normalized|
            normalized[key.respond_to?(:to_sym) ? key.to_sym : key] = value
          end
        end

        def dedupe_offerings(list)
          list.each_with_object({}) do |offering, seen|
            key = [offering[:provider_family], offering[:provider_instance], offering[:model], offering[:type]]
            current = seen[key]
            seen[key] = offering if current.nil? || source_priority(offering) > source_priority(current)
          end.values
        end

        def source_priority(offering)
          case offering[:source].to_s
          when 'discovery'
            3
          when 'settings', 'settings_embedding'
            2
          else
            1
          end
        end

        def filter_offerings(list, filters)
          list.select do |offering|
            filter_matches?(offering, filters)
          end
        end

        def normalize_filter_hash(filters)
          filters.transform_keys(&:to_sym).compact
        end

        def filter_matches?(offering, filters)
          filters.all? do |key, value|
            next true if value.nil? || value.to_s.empty?

            case key
            when :provider, :provider_family
              offering[:provider_family] == value.to_s
            when :instance, :instance_id
              offering[:instance_id] == value.to_s || offering[:provider_instance] == value.to_s
            when :model, :id
              offering[:model] == value.to_s || offering[:id] == value.to_s ||
                offering[:offering_id] == value.to_s || offering[:canonical_model_alias] == value.to_s
            when :offering_id
              offering[:offering_id] == value.to_s || offering[:id] == value.to_s
            when :model_family, :family
              offering[:model_family] == value.to_s
            when :tier
              offering[:tier].to_s == value.to_s
            when :healthy
              healthy_filter_matches?(offering, value)
            when :type, :purpose
              offering[:type].to_s == normalize_type(value).to_s
            when :capability
              offering[:capabilities].include?(value.to_s)
            else
              true
            end
          end
        end

        def healthy_filter_matches?(offering, value)
          expected = %w[1 true yes].include?(value.to_s.downcase)
          unhealthy = %w[open tripped unhealthy down unavailable].include?(offering.dig(:health, :circuit_state).to_s)
          expected ? !unhealthy : unhealthy
        end
      end
    end
  end
end
