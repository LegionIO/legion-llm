# frozen_string_literal: true

require 'concurrent'
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

      CAPABILITY_ALIASES = {
        function_calling: :tools,
        functions:        :tools,
        tool:             :tools,
        tool_use:         :tools,
        stream:           :streaming,
        stream_chat:      :streaming
      }.freeze

      class << self
        # Correlation-keyed call/time accounting for P0 baseline capture.
        # exchange_id: is threaded explicitly by callers that have it; falls back to
        # Thread.current[:p0_exchange_id] (set by the executor before its routing step)
        # so indirect router calls (Inventory.routing_candidates, availability checks)
        # are captured without signature churn on every intermediate method.
        def offerings(filters = {})
          eid = Thread.current[:p0_exchange_id]
          if eid
            @capture_counters ||= Concurrent::Map.new
            counters = @capture_counters.compute_if_absent(eid) { { calls: 0, total_ms: 0.0 } }
            counters[:calls] += 1
            started = ::Process.clock_gettime(::Process::CLOCK_MONOTONIC)
            result = compose_offerings(filters: filters)
            counters[:total_ms] += (::Process.clock_gettime(::Process::CLOCK_MONOTONIC) - started) * 1000.0
            result
          else
            compose_offerings(filters: filters)
          end
        end

        def capture_summary(exchange_id:, **)
          @capture_counters&.delete(exchange_id) || { calls: 0, total_ms: 0.0 }
        end

        def providers
          compose_offerings(filters: {}).group_by { |offering| offering[:provider_family] }
        end

        # Filtered read of the live catalog. Returns Array<offering>. No grouping, no defaults,
        # no special cases — that's the caller's job. Filters are AND-combined; nil = match-all.
        # After P1/commit 5 this is backed by the Concurrent::Map live store; until then it
        # delegates to offerings() so every intermediate commit stays green.
        def lanes_for(provider: nil, instance: nil, type: nil, model: nil, **)
          filters = {}
          filters[:provider] = provider if provider
          filters[:instance] = instance if instance
          filters[:type]     = type     if type
          filters[:model]    = model    if model
          offerings(filters)
        end

        # Bounded routing-candidate set: ONE representative offering per enabled
        # provider-instance for the given operation, drawn from the SAME merged
        # catalog the API serves (settings + native adapter static catalogs +
        # discovery). This is the set the Router scores — it never enumerates a
        # provider's full catalog (e.g. OpenAI's 100+ models). The representative
        # is the provider's declared default_model when that model is offered,
        # else the settings-default offering, else the first offering.
        def routing_candidates(operation: :generation, **filters)
          type = normalize_type(operation)
          catalog = offerings(filters.merge(type: type))
          catalog
            .group_by { |offering| [offering[:provider_family].to_s, offering_instance_key(offering)] }
            .filter_map { |(provider_family, instance_key), group| representative_offering(provider_family, instance_key, group) }
        end

        private

        def compose_offerings(filters:, **)
          log.debug "[llm][inventory] action=offerings.enter filters=#{filters.keys}"
          normalized_filters = normalize_filter_hash(filters)
          provider_scope = normalized_filters[:provider]&.to_sym
          list = []
          providers_config.each do |provider_family, config|
            next unless enabled_config?(config)
            next if provider_scope && provider_family.to_sym != provider_scope

            list.concat(provider_offerings(provider_family.to_sym, config))
          end

          native = native_provider_offerings(provider: provider_scope)
          native_providers = native.map { |o| o[:provider_family]&.to_sym }.uniq
          list.concat(native)
          list.concat(discovery_offerings(provider: provider_scope, exclude_providers: native_providers))
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

        # --- routing-candidate selection (one representative offering / instance) ---

        def offering_instance_key(offering)
          inst = offering[:instance_id] || offering[:provider_instance]
          inst.to_s.empty? ? 'default' : inst.to_s
        end

        def representative_offering(provider_family, instance_key, group)
          return group.first if group.size <= 1

          default_model = registry_default_model_for(provider_family, instance_key)
          if default_model
            match = group.find do |offering|
              offering[:model] == default_model || offering[:canonical_model_alias] == default_model
            end
            return match if match
          end
          group.find { |offering| offering[:source].to_s == 'settings_default' } || group.first
        end

        def registry_default_model_for(provider_family, instance_key)
          return nil unless defined?(Legion::LLM::Call::Registry)

          provider = provider_family.to_sym
          # A settings-configured offering defaults its instance to the provider
          # family, while the registry registers under :default — try both.
          [instance_key.to_sym, :default].uniq.each do |inst|
            meta = Legion::LLM::Call::Registry.metadata_for(provider, inst)
            dm = meta.is_a?(Hash) ? (meta[:default_model] || meta['default_model']) : nil
            return dm.to_s if dm && !dm.to_s.empty?
          end
          nil
        rescue StandardError => e
          handle_exception(e, level: :debug, handled: true, operation: 'llm.inventory.registry_default_model')
          nil
        end

        def providers_config
          ext = Legion::Settings[:extensions]
          return ext[:llm] if ext.is_a?(Hash) && ext[:llm].is_a?(Hash)

          {}
        rescue StandardError => e
          handle_exception(e, level: :warn, handled: true, operation: 'llm.inventory.providers_config')
          {}
        end

        def embedding_settings
          Legion::Settings[:llm][:embedding]
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
          if model.empty?
            log.warn("[llm][inventory] invalid_offering provider=#{provider_family} reason=missing_model")
            return nil
          end

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
            health:                provider_health(provider_family, resolved_offering_id, model: model),
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
          Array(raw).compact.each_with_object([]) do |capability, normalized|
            next unless capability.respond_to?(:to_s)

            capability_sym = capability.to_s.downcase.strip.to_sym
            next if capability_sym.to_s.empty?

            normalized << capability_sym
            alias_sym = CAPABILITY_ALIASES[capability_sym]
            normalized << alias_sym if alias_sym
          end.uniq.map(&:to_s).sort
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

        def provider_health(provider_family, offering_id = nil, model: nil)
          unless defined?(Legion::LLM::Router) && Legion::LLM::Router.respond_to?(:routing_enabled?) &&
                 Legion::LLM::Router.routing_enabled?
            return { circuit_state: 'unknown' }
          end

          tracker = Legion::LLM::Router.health_tracker
          circuit = tracker.circuit_state(provider_family, offering_id: offering_id).to_s
          denied = model ? tracker.model_denied?(provider: provider_family, model: model) : false
          {
            circuit_state: circuit,
            adjustment:    tracker.adjustment(provider_family, offering_id: offering_id),
            denied:        denied,
            available:     !denied && %w[closed half_open unknown].include?(circuit)
          }
        end

        def add_fleet_lane(offering)
          return offering unless defined?(Legion::LLM::Fleet::Lane)

          context_window = offering.dig(:limits, :context_window)
          # The model-keyed routing lane never carries the instance name, so it is
          # always safe to build.
          lanes = { fleet_lane: Legion::LLM::Fleet::Lane.routing_key(
            operation:      offering[:type],
            model:          offering[:model],
            context_window: context_window
          ) }
          # The per-offering lane embeds the instance id. Fleet::Lane sanitizes the
          # label (internal datacenter RabbitMQ, so a label like "env_bearer" is a
          # routing label, not secret material) but still raises if it is empty or
          # over-length after sanitization. A malformed label must not break the
          # offering or make the instance unroutable — it just gets no fleet lane.
          begin
            lanes[:fleet_offering_lane] = Legion::LLM::Fleet::Lane.offering_key(
              instance_id: offering[:provider_instance],
              model:       offering[:model],
              operation:   offering[:type]
            )
          rescue ArgumentError => e
            log.debug('[llm][inventory] action=fleet_offering_lane.skipped ' \
                      "instance=#{offering[:provider_instance]} model=#{offering[:model]} reason=#{e.message}")
          end
          offering.merge(lanes)
        end

        def discovery_offerings(provider: nil, exclude_providers: [])
          return [] unless defined?(Legion::LLM::Discovery)

          cached_models = if Legion::LLM::Discovery.respond_to?(:cached_discovered_models)
                            Legion::LLM::Discovery.cached_discovered_models
                          else
                            Legion::LLM::Discovery.discovered_models
                          end

          cached_models.filter_map do |model_entry|
            provider_family = model_entry[:provider]
            next if provider && provider_family.to_sym != provider
            next if exclude_providers.include?(provider_family.to_sym)

            config = option(providers_config, provider_family, {})
            next unless enabled_config?(config)

            model_name = model_entry[:model]
            entry = {
              model:          model_name,
              type:           infer_model_type(model_name),
              source:         :discovery,
              context_window: model_entry[:context_length]
            }
            inst = model_entry[:instance]
            entry[:instance_id] = inst if inst && inst != :default
            build_offering(provider_family, config, entry)
          end
        rescue StandardError => e
          handle_exception(e, level: :warn, handled: true, operation: 'llm.inventory.discovery')
          []
        end

        def native_provider_offerings(provider: nil)
          return [] unless defined?(Legion::LLM::Call::Registry)

          Legion::LLM::Call::Registry.all_instances.flat_map do |entry|
            provider_name = entry[:provider]
            next [] if provider && provider_name.to_sym != provider

            adapter = entry[:adapter]
            next [] unless adapter.respond_to?(:offerings)

            Array(adapter.offerings(live: false)).filter_map do |offering|
              normalize_native_offering(provider_name, offering, instance: entry[:instance])
            end
          rescue StandardError => e
            handle_exception(e, level: :warn, handled: true, operation: 'llm.inventory.native_provider',
                                provider: provider_name)
            []
          end
        end

        def normalize_native_offering(provider_name, offering, instance: nil)
          data = normalize_hash(offering.respond_to?(:to_h) ? offering.to_h : offering)
          provider_family = normalize_symbol(option(data, :provider_family) || option(data, :provider) || provider_name)
          # The registry instance Inventory is enumerating is authoritative — it is the
          # key dispatch routes by (Registry.for(provider, instance:)). Prefer it over
          # the adapter's self-reported instance, which is often a generic "default"
          # because the adapter was not told its registration name — that collapsed
          # multiple configured cloud instances (e.g. two Anthropic accounts) into one.
          provider_instance = instance || option(data, :provider_instance) || option(data, :instance_id)
          usage_type = option(data, :usage_type)
          entry = data.merge(
            model:             option(data, :model),
            # Override BOTH keys so build_offering (which prefers :provider_instance)
            # can't fall back to the adapter's stale self-reported value.
            provider_instance: provider_instance,
            instance_id:       provider_instance,
            type:              normalize_type(usage_type || option(data, :type)),
            source:            :native_provider,
            metadata:          normalize_hash(option(data, :metadata))
          )
          build_offering(provider_family, {}, entry)
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
            instance = offering[:provider_instance]
            instance = nil if instance.to_s == 'default'
            key = [offering[:provider_family], instance, offering[:model], offering[:type]]
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
            when :type, :purpose, :operation
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
