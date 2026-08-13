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

      class << self
        # ── P1 live store write API ───────────────────────────────────────────────

        # Upsert a lane into the live Concurrent::Map store.
        # Validates shape (G22), applies policy filter, preserves existing health
        # unless explicit health: kwarg is given (G21 / health: :preserve sentinel),
        # computes lane_weight (G23), freezes the entry on write (M10).
        def write_lane(lane:, ttl: nil, health: :preserve, **)
          validate_lane!(lane: lane)
          return policy_skip(lane: lane) if policy_denied?(lane: lane)

          lane = enrich_lane_range(lane: lane)

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
          log.debug("[llm][inventory] action=write_lane.written provider=#{lane[:provider_family]} model=#{lane[:model]} instance=#{lane[:instance_id]} tier=#{lane[:tier]}")
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

        # Filtered read of the catalog. Reads the live Concurrent::Map store.
        # Returns Array<lane> (dups so callers cannot mutate the live store).
        def offerings(filters = {}, **)
          normalized = normalize_filter_hash(filters.merge(**))
          total_in_map = live_map.size
          list = lanes
          provider_matches = normalized[:provider] ? list.count { |l| l[:provider_family]&.to_s == normalized[:provider]&.to_s } : 0
          all_providers = list.group_by { |l| l[:provider_family]&.to_s }.transform_values(&:count)
          log.unknown(
            "[llm][inventory] action=offerings provider=#{normalized[:provider] || 'all'} " \
            "total_in_map=#{total_in_map} after_ttl=#{list.size} " \
            "provider_matches=#{provider_matches} all_providers=#{all_providers}"
          )
          list = list.select { it[:provider_family].to_s == normalized[:provider].to_s } if normalized[:provider]
          list = list.select { [it[:instance_id].to_s, it[:provider_instance].to_s].include?(normalized[:instance].to_s) } if normalized[:instance]
          list = list.select { it[:type].to_s == normalize_type(normalized[:type]).to_s } if normalized[:type]
          if normalized[:model] && normalized[:offering_id]
            list = list.select { it[:model].to_s == normalized[:model].to_s || it[:offering_id].to_s == normalized[:offering_id].to_s }
          elsif normalized[:model]
            list = list.select { it[:model].to_s == normalized[:model].to_s }
          elsif normalized[:offering_id]
            list = list.select { it[:offering_id].to_s == normalized[:offering_id].to_s || it[:id].to_s == normalized[:offering_id].to_s }
          end
          list = list.select { it[:enabled] } unless normalized[:include_disabled]
          list.map(&:dup)
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

        # ── SSOT v3 Phase 2 read-only facade ─────────────────────────────────────
        # §13.1: projection surface over an immutable Phase 1 snapshot.
        # NOTE: `providers`, `offerings`, and `lanes` exist on this module with
        # incompatible signatures (live Concurrent::Map readers); those collisions
        # are reported and the SSOT v3 equivalents are deferred until the live-store
        # write API is removed in a later migration task.

        VALID_FILTER_KEYS = %i[provider_family instance_id model tier operation availability].freeze
        private_constant :VALID_FILTER_KEYS

        # Returns the live Phase 1 snapshot (no args; generation-tagged).
        def snapshot
          Legion::Extensions::Llm::Inventory::Registry.snapshot
        end

        # Projects distinct, frozen, sorted provider-family Strings from the
        # supplied snapshot.  Filters: :provider_family, :instance_id, :tier,
        # :operation, :availability.  Unknown filter keys raise ArgumentError.
        #
        # NOTE: a `providers` method with a different signature already exists on
        # this module (returns a Hash grouped from the live Concurrent::Map store).
        # This method is named `providers_from` as a non-colliding bridge until the
        # old writer is removed and `providers` can be reassigned to this signature.
        def providers_from(snapshot:, filters: {}, **)
          validate_filter_keys!(filters)
          result = []
          snapshot.each_instance do |inst|
            next if filter_mismatch_instance?(inst, filters)

            family = inst.instance_key.provider_family.to_s
            result << family unless result.include?(family)
          end
          result.sort.freeze
        end

        # Projects frozen Array<Hash> of instance data from the supplied snapshot in
        # canonical InstanceKey order. Filters: :provider_family, :instance_id,
        # :availability. Unknown filter keys raise ArgumentError.
        def instances(snapshot:, filters: {}, **)
          validate_filter_keys!(filters)
          result = []
          snapshot.each_instance do |inst|
            next if filter_mismatch_instance?(inst, filters)

            result << project_instance(inst)
          end
          result.freeze
        end

        # Projects distinct, sorted, frozen Array<String> of model names from the
        # supplied snapshot. Filters: :provider_family, :instance_id, :tier,
        # :operation. Unknown filter keys raise ArgumentError.
        def models(snapshot:, filters: {}, **)
          validate_filter_keys!(filters)
          result = []
          snapshot.each_offering do |offering|
            next if filter_mismatch_offering?(offering, filters)

            model = offering.model
            result << model unless result.include?(model)
          end
          result.sort.freeze
        end

        # ── end SSOT v3 Phase 2 read-only facade ─────────────────────────────────

        private

        # ── P1 live store private helpers ────────────────────────────────────────

        def live_map
          @live_map ||= Concurrent::Map.new
        end

        def default_health
          { circuit_state: :closed, denied: false, available: true, adjustment: 0 }.freeze
        end

        def policy_skip(lane:)
          log.unknown(
            "[llm][inventory] action=write_lane.skipped reason=policy_denied id=#{lane[:id]} " \
            "provider=#{lane[:provider_family]} model=#{lane[:model]} " \
            "tier=#{lane[:tier]} instance=#{lane[:instance_id]}"
          )
          nil
        end

        # G22: 5-part id required (tier:provider:instance:type:model).
        # No derivation fallback — gem writers must use ScopedRefresher.compose_id.
        def validate_lane!(lane:)
          raise Legion::LLM::InvalidLane, ':id required' if lane[:id].nil? || lane[:id].to_s.empty?

          parts = lane[:id].to_s.split(':', 5)
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

        def enrich_lane_range(lane:)
          provider_settings = Legion::Settings.dig(:extensions, :llm, lane[:provider_family].to_sym)
          return lane unless provider_settings.is_a?(Hash)

          instances = provider_settings[:instances]
          return lane unless instances.is_a?(Hash)

          inst_cfg = instances[lane[:instance_id]] || instances[lane[:instance_id]&.to_sym]
          return lane unless inst_cfg.is_a?(Hash)

          min_val = inst_cfg[:preferred_min_context_tokens]
          max_val = inst_cfg[:preferred_max_context_tokens]
          return lane if min_val.nil? && max_val.nil?

          enriched = lane.dup
          enriched[:preferred_min_context_tokens] = min_val if min_val
          enriched[:preferred_max_context_tokens] = max_val if max_val
          enriched
        end

        def lane_weights_from_settings(lane:)
          tier_weights    = Legion::Settings.dig(:llm, :routing, :tier_weights) || {}
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
          model    = lane[:model].to_s.downcase
          sets     = policy_sets_for(provider: provider)

          # Whitelist takes precedence over blacklist (M2).  Substring match —
          # a model is denied if NO whitelist pattern is contained in its name. # -- substring checks (patterns
          # `include?`d in the model name), NOT array intersection; `intersect?`
          # raises TypeError on the String arg.
          if sets[:whitelist]
            return true if sets[:whitelist].none? { |p| model.include?(p) }

            return false
          end

          sets[:blacklist]&.any? { |p| model.include?(p) } || false
        end

        # Specificity cascade — same precedence as lex-llm Provider#model_whitelist:
        # 1. Provider-level  extensions.llm.<provider>.model_whitelist
        # 2. Global          extensions.llm.model_whitelist
        # If no whitelist is found anywhere, whitelist is nil (allow all).
        def policy_sets_for(provider:)
          @policy_sets ||= Concurrent::Map.new
          @policy_sets.compute_if_absent(provider) do
            provider_settings = Legion::Settings.dig(:extensions, :llm, provider)
            provider_settings ||= {} unless provider_settings.is_a?(Hash)

            global_settings = Legion::Settings.dig(:extensions, :llm)
            global_settings ||= {} unless global_settings.is_a?(Hash)

            # Resolve whitelist/blacklist with cascade: provider → global
            whitelist = resolve_policy_array(provider_settings, global_settings, :model_whitelist)
            blacklist = resolve_policy_array(provider_settings, global_settings, :model_blacklist)

            {
              whitelist: whitelist ? Set.new(Array(whitelist).map { |p| p.to_s.downcase }) : nil,
              blacklist: Set.new(Array(blacklist).map { |p| p.to_s.downcase })
            }.freeze.tap do |sets|
              wl_count = sets[:whitelist] ? sets[:whitelist].size : 0
              bl_count = sets[:blacklist]&.size || 0
              wl_sample = sets[:whitelist] ? sets[:whitelist].first(3).to_a.join(',') : 'nil'
              log.debug("[llm][inventory] action=policy_sets_for provider=#{provider} wl=#{wl_count} bl=#{bl_count} sample=[#{wl_sample}]")
            end
          end
        end

        # Pick the first non-empty array value: provider-level, then global, then nil.
        def resolve_policy_array(provider_settings, global_settings, key)
          val = provider_settings[key] || provider_settings[key.to_s]
          return val if val && (val.is_a?(Array) ? val.any? : !val.to_s.empty?)

          val = global_settings[key] || global_settings[key.to_s]
          return val if val && (val.is_a?(Array) ? val.any? : !val.to_s.empty?)

          nil
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

        def normalize_filter_hash(filters)
          filters.transform_keys(&:to_sym).compact
        end

        # ── SSOT v3 private filter/projection helpers ─────────────────────────────

        def validate_filter_keys!(filters)
          unknown = filters.keys.map(&:to_sym) - VALID_FILTER_KEYS
          raise ArgumentError, "unknown filter key(s): #{unknown.join(', ')}" unless unknown.empty?
        end

        # Returns true when the instance should be excluded by the supplied filters.
        def filter_mismatch_instance?(inst, filters)
          key = inst.instance_key
          fam = filters[:provider_family]
          iid = filters[:instance_id]
          avail = filters[:availability]
          return true if fam  && key.provider_family.to_s != fam.to_s
          return true if iid  && key.instance_id != iid.to_s
          return true if avail && inst.availability.state != avail.to_sym

          false
        end

        # Returns true when the offering should be excluded by the supplied filters.
        def filter_mismatch_offering?(offering, filters)
          key = offering.instance_key
          fam = filters[:provider_family]
          iid = filters[:instance_id]
          mod = filters[:model]
          tier = filters[:tier]
          op = filters[:operation]
          return true if fam  && key.provider_family.to_s != fam.to_s
          return true if iid  && key.instance_id != iid.to_s
          return true if mod  && offering.model != mod.to_s
          return true if tier && offering.tier != tier.to_sym
          return true if op   && offering.operation_status(operation: op.to_sym) != :supported

          false
        end

        # Projects a frozen Hash of safe, non-callable fields from an InstanceRecord.
        def project_instance(inst)
          key = inst.instance_key
          {
            provider_family:    key.provider_family,
            instance_id:        key.instance_id,
            availability:       inst.availability.state,
            publisher_id:       inst.publisher_id,
            publisher_token_id: inst.publisher_token_id,
            published_sequence: inst.published_sequence,
            published_at:       inst.published_at
          }.freeze
        end

        # ── end SSOT v3 private filter/projection helpers ─────────────────────────
      end
    end
  end
end
