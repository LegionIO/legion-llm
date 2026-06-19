# frozen_string_literal: true

require 'concurrent'
require 'legion/logging/helper'
require 'legion/llm/errors'

module Legion
  module LLM
    module Inventory
      extend Legion::Logging::Helper

      # Taxonomy enums — inline until lex-llm ships Legion::Extensions::Llm::Taxonomies (commit 6a).
      # :fleet is first-class per the SSOT plan (operators can set x-legion-tiers: fleet).
      LANE_TIERS  = %i[direct local fleet cloud frontier].freeze
      LANE_TYPES  = %i[inference embedding image audio embed].freeze

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
        # ── P1 live store write API ───────────────────────────────────────────────

        # Upsert a lane into the live Concurrent::Map store.
        # Validates shape (G22), applies policy filter, preserves existing health
        # unless explicit health: kwarg is given (G21 / health: :preserve sentinel),
        # computes lane_weight (G23), freezes the entry on write (M10).
        def write_lane(lane:, ttl: nil, health: :preserve, **)
          validate_lane!(lane: lane)
          return policy_skip(lane: lane) if policy_denied?(lane: lane)

          existing = live_map[lane[:id]]
          resolved_health = if health == :preserve
                              existing&.dig(:health) || default_health
                            else
                              health
                            end

          enriched = lane.merge(
            lane_weight: compute_lane_weight(lane: lane, health: resolved_health),
            health:      resolved_health.freeze,
            expires_at:  ttl ? Time.now.to_f + ttl : nil
          ).freeze

          live_map.put(lane[:id], enriched)
          enriched
        end

        # Remove a lane. Warn-logs (not debug) if the id is not present (standing rule).
        def delete_lane(id:, **)
          removed = live_map.delete(id)
          log.warn("[llm][inventory] action=delete_lane.miss id=#{id}") if removed.nil?
          removed
        end

        # Single lane lookup (TTL-aware). Returns nil if absent or expired.
        def lane(id:, **)
          entry = live_map[id]
          return nil if entry.nil?
          return nil if entry[:expires_at] && entry[:expires_at] < Time.now.to_f

          entry
        end

        # All live (non-expired) lanes as an Array snapshot.
        def lanes(**)
          now = Time.now.to_f
          live_map.each_pair.filter_map { |_id, entry| entry unless entry[:expires_at] && entry[:expires_at] < now }
        end

        # IDs of lanes whose expires_at is in the past. Used by Sweeper — never .send(:map).
        def expired_ids(**)
          now = Time.now.to_f
          live_map.each_pair.filter_map { |id, entry| id if entry[:expires_at] && entry[:expires_at] < now }
        end

        # Reset the live store (for test isolation).
        def reset_live_store!
          @live_map = Concurrent::Map.new
          @policy_sets = Concurrent::Map.new
        end

        # ── end P1 live store write API ───────────────────────────────────────────

        # Filtered read of the catalog. Reads from the live Concurrent::Map store first;
        # falls back to the legacy recompute path (compose_offerings) when the live store
        # is empty (e.g. actors haven't ticked yet, test env without pre-populated store).
        # The recompute fallback is removed in P3 once all callers have migrated.
        #
        # Accepts a Hash of filters (legacy positional) or keyword args pattern.
        # Returns Array<lane/offering> (dups so callers cannot mutate the live store).
        def offerings(filters = {}, **)
          normalized = normalize_filter_hash(filters.merge(**))
          live = lanes
          if live.any?
            list = live
            list = list.select { it[:provider_family].to_s == normalized[:provider].to_s } if normalized[:provider]
            list = list.select { [it[:instance_id].to_s, it[:provider_instance].to_s].include?(normalized[:instance].to_s) } if normalized[:instance]
            list = list.select { it[:type].to_s == normalize_type(normalized[:type]).to_s } if normalized[:type]
            list = list.select { it[:model].to_s == normalized[:model].to_s || it[:offering_id].to_s == normalized[:offering_id].to_s } if normalized[:model] || normalized[:offering_id]
            list = list.select { it[:enabled] } unless normalized[:include_disabled]
            return list.map(&:dup)
          end

          # Fallback: live store empty — recompute from settings+registry+discovery.
          compose_offerings(filters: normalized)
        end

        def providers
          lanes.group_by { |l| l[:provider_family].to_s }
        end

        # Filtered read of live lanes. Returns Array<lane> from the Concurrent::Map store.
        # Filters are AND-combined; nil = match-all. TTL-aware (expired lanes excluded).
        def lanes_for(provider: nil, instance: nil, type: nil, model: nil, **)
          lanes.select do |l|
            next false if provider && l[:provider_family].to_sym != provider.to_sym
            next false if instance && l[:instance_id].to_sym != instance.to_sym
            next false if type     && l[:type].to_sym != type.to_sym
            next false if model    && l[:model].to_s != model.to_s

            true
          end
        end

        private

        # ── P1 live store private helpers ────────────────────────────────────────

        def live_map
          @live_map ||= Concurrent::Map.new
        end

        def default_health
          { circuit_state: :closed, denied: false, available: true, adjustment: 0 }.freeze
        end

        def policy_skip(lane:)
          log.warn("[llm][inventory] action=write_lane.skipped reason=policy_denied id=#{lane[:id]}")
          nil
        end

        # G22: 5-part id required (tier:provider:instance:type:model).
        # No derivation fallback — gem writers must use ScopedRefresher.compose_id.
        def validate_lane!(lane:)
          raise Legion::LLM::InvalidLane, ':id required' if lane[:id].nil? || lane[:id].to_s.empty?

          parts = lane[:id].to_s.split(':')
          raise Legion::LLM::InvalidLane, "5-part id required, got #{parts.size}: #{lane[:id]}" if parts.size != 5

          %i[tier provider_family instance_id type model].each do |k|
            raise Legion::LLM::InvalidLane, "lane[:#{k}] required" if lane[k].nil?
          end

          unless LANE_TIERS.include?(lane[:tier].to_sym)
            raise Legion::LLM::InvalidLane,
                  "invalid tier #{lane[:tier]}; expected one of #{LANE_TIERS}"
          end

          return if LANE_TYPES.include?(lane[:type].to_sym)

          raise Legion::LLM::InvalidLane,
                "invalid type #{lane[:type]}; expected one of #{LANE_TYPES}"
        end

        # G23: denied flips sign × -1.0 preserving magnitude (NOT × 0).
        def compute_lane_weight(lane:, health:)
          weights = lane_weights_from_settings(lane: lane)
          base = weights[:tier] * weights[:provider] * weights[:instance] * weights[:model]
          health_mult = case health[:circuit_state].to_sym
                        when :half_open then 0.5
                        when :open      then -1.0
                        else                  1.0
                        end
          health_mult = -1.0 if health[:denied] && health_mult.positive?
          (base * health_mult).to_i
        end

        def lane_weights_from_settings(lane:)
          tier_weights    = Legion::Settings[:llm][:routing][:tier_weights]
          provider_sym    = lane[:provider_family].to_sym
          provider_settings = Legion::Settings.dig(:extensions, :llm, provider_sym) || {}
          provider_weight = provider_settings.is_a?(Hash) ? (provider_settings[:weight] || 100) : 100
          instances       = provider_settings.is_a?(Hash) ? (provider_settings[:instances] || {}) : {}
          models          = provider_settings.is_a?(Hash) ? (provider_settings[:models] || {}) : {}
          inst_cfg        = instances[lane[:instance_id]] || instances[lane[:instance_id]&.to_sym] || {}
          model_cfg       = models[lane[:model]] || models[lane[:model]&.to_sym] || {}
          tier_w          = tier_weights.is_a?(Hash) ? (tier_weights[lane[:tier]] || tier_weights[lane[:tier]&.to_sym] || 100) : 100
          {
            tier:     tier_w,
            provider: provider_weight,
            instance: inst_cfg.is_a?(Hash) ? (inst_cfg[:weight] || 100) : 100,
            model:    model_cfg.is_a?(Hash) ? (model_cfg[:weight] || 100) : 100
          }
        end

        # Memoized policy sets per provider; invalidated by SettingsObserver (G28).
        def policy_denied?(lane:)
          provider = lane[:provider_family].to_sym
          model    = lane[:model].to_s
          sets     = policy_sets_for(provider: provider)

          # Whitelist takes precedence over blacklist (M2).
          return !sets[:whitelist].include?(model) if sets[:whitelist]

          sets[:blacklist].include?(model)
        end

        def policy_sets_for(provider:)
          @policy_sets ||= Concurrent::Map.new
          @policy_sets.compute_if_absent(provider) do
            provider_settings = Legion::Settings.dig(:extensions, :llm, provider)
            next { whitelist: nil, blacklist: Set.new } unless provider_settings.is_a?(Hash)

            whitelist = provider_settings[:model_whitelist] || provider_settings['model_whitelist']
            blacklist = provider_settings[:model_blacklist] || provider_settings['model_blacklist'] || []
            {
              whitelist: whitelist ? Set.new(Array(whitelist).map(&:to_s)) : nil,
              blacklist: Set.new(Array(blacklist).map(&:to_s))
            }.freeze
          end
        end

        def invalidate_policy_sets!(provider: nil, **)
          @policy_sets ||= Concurrent::Map.new
          if provider
            @policy_sets.delete(provider)
          else
            @policy_sets.clear
          end
        end

        # ── end P1 live store private helpers ────────────────────────────────────

        # Legacy recompute path — still used as fallback when live store is empty.
        # Removed in P3 once lex-llm-* gems populate the store reliably.
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
          handle_exception(e, level: :warn, handled: true, operation: 'llm.inventory.registry_default_model')
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

        def provider_health(provider_family, _offering_id = nil, model: nil)
          # Read health from Inventory lanes (P2: lane is the SSOT for health).
          # Falls back to unknown when no lanes exist (cold-boot).
          provider = provider_family.to_sym
          lanes = lanes_for(provider: provider)
          model_lanes = model ? lanes.select { |l| l[:model].to_s == model.to_s } : lanes
          target = model_lanes.first || lanes.first

          if target
            h = target[:health]
            circuit = h[:circuit_state].to_s
            denied  = h[:denied]
          else
            circuit = 'unknown'
            denied  = false
          end
          adjustment = target ? target[:health][:adjustment].to_i : 0

          {
            circuit_state: circuit,
            adjustment:    adjustment,
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
          # Use Legion::LLM::Discovery (compat shim) so allow() mocks in specs work.
          # In production, this delegates to Inventory::Discovery via method_missing.
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
