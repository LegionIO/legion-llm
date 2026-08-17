# frozen_string_literal: true

require 'bigdecimal'
require 'legion/extensions/llm/settings_cascade'

module Legion
  module LLM
    module Router
      # Immutable, validated snapshot of all selection-relevant settings for one
      # reload generation.  Built once by SettingsState.install!/reload! and
      # consumed read-only by every selection call.  Runtime selection never
      # reaches back into Legion::Settings.
      class SettingsSnapshot
        include Legion::Logging::Helper

        TIER_KEYS             = %i[direct local fleet cloud frontier].freeze
        ALLOWED_ALIAS_META    = %i[owned_by created context_window max_output_tokens].freeze
        IDENTITY_WEIGHT       = 1
        # Shared 3-level settings cascade (lex-llm): provider -> instance ->
        # model, most-specific-first. The instance leg is the operator's
        # CONFIG NAME (InstanceKey#instance_id), never a derived id.
        CASCADE               = Legion::Extensions::Llm::SettingsCascade
        private_constant :TIER_KEYS, :ALLOWED_ALIAS_META, :IDENTITY_WEIGHT, :CASCADE

        # ------------------------------------------------------------------ #
        # Public factory                                                       #
        # ------------------------------------------------------------------ #

        def self.build(generation:, llm_settings:, extension_settings:)
          snap = new(generation:         generation,
                     llm_settings:       llm_settings,
                     extension_settings: extension_settings)
          snap.freeze
          snap
        end

        # ------------------------------------------------------------------ #
        # Readers                                                              #
        # ------------------------------------------------------------------ #

        attr_reader :generation,
                    :tier_weights,
                    :context_headroom_ppm,
                    :input_framing_overhead_tokens,
                    :affinity_strength_bps,
                    :maximum_attempts,
                    :routing_too_early_retry_after,
                    :allow_body_routing_hints,
                    :body_model_hint_whitelist,
                    :body_model_hint_blacklist,
                    :auto_routing_model_aliases,
                    :auto_routing_model_alias_metadata

        # ------------------------------------------------------------------ #
        # Per-lane weight inputs (called per candidate during ranking)        #
        # ------------------------------------------------------------------ #

        # Returns a frozen Hash { tier:, provider:, instance:, model_or_offering: }
        # where each value is a positive Integer >= 1 (missing component → identity 1).
        # The provider/instance/model scopes are read through the lex-llm
        # cascade, keyed by the config name (lane.instance_id): the instance
        # leg is instances.<name>, the model leg is the instance's models.<model>
        # entry overriding the provider's models.<model> entry. A zero tier
        # weight is stored as-is (disabled lane); callers check for zero.
        def weight_inputs_for(lane:)
          tier_w  = tier_weights[lane.tier] || IDENTITY_WEIGHT
          prov    = ext_llm_provider(lane.provider_family)
          inst    = ext_llm_instance(prov, lane.instance_id)
          prov_w  = CASCADE.lookup(prov, :weight) || IDENTITY_WEIGHT
          inst_w  = CASCADE.lookup(inst, :weight) || IDENTITY_WEIGHT
          off_entry = CASCADE.lookup(CASCADE.lookup(prov, :offerings), lane.offering_id)
          model_cfg = CASCADE.merge_model_scopes(provider_conf: prov, instance_cfg: inst, model: lane.model)
          model_w = CASCADE.lookup(off_entry, :weight) || CASCADE.lookup(model_cfg, :weight) || IDENTITY_WEIGHT
          { tier: tier_w, provider: prov_w, instance: inst_w, model_or_offering: model_w }.freeze
        end

        # Returns { min: Integer_or_nil, max: Integer_or_nil } or nil when no
        # preferred range is configured. Resolved through the lex-llm 3-level
        # cascade (provider -> instance -> model, most-specific-first) keyed
        # by the config name, so a provider- or model-level leg can supply
        # either bound.
        def preferred_context_range_for(lane:)
          min_v = cascade_value(provider_family: lane.provider_family, instance_id: lane.instance_id,
                                key: :preferred_min_context_tokens, model: lane.model)
          max_v = cascade_value(provider_family: lane.provider_family, instance_id: lane.instance_id,
                                key: :preferred_max_context_tokens, model: lane.model)
          return nil unless min_v || max_v

          { min: min_v, max: max_v }.freeze
        end

        # The operator's cascaded enable_<capability> routing override for the
        # exact instance (config name), resolved through the lex-llm 3-level
        # cascade (provider -> instance -> model, most-specific-first).
        # Returns true or false when the operator configured it; nil when unset.
        # Routing-side read only: providers do not publish the override as
        # capability evidence (config remains unknown-only evidence).
        def capability_override_for(provider_family:, instance_id:, capability:, model:)
          cascade_value(provider_family: provider_family, instance_id: instance_id,
                        key: :"enable_#{capability}", model: model)
        end

        # Returns { whitelist: Array<String>, blacklist: Array<String> } using the
        # §9.5 specificity cascade: exact provider+instance → provider → global.
        # "First scope whose key EXISTS, including explicit empty Array."
        def model_policy_for(offering:)
          ik   = offering.instance_key
          pf   = ik.provider_family   # Symbol
          iid  = ik.instance_id       # String
          prov = ext_llm_provider(pf)
          inst = ext_llm_instance(prov, iid)

          wl = first_existing_policy(inst, prov, :model_whitelist)
          bl = first_existing_policy(inst, prov, :model_blacklist)

          { whitelist: Array(wl).freeze, blacklist: Array(bl).freeze }.freeze
        end

        # ------------------------------------------------------------------ #
        # Private construction                                                 #
        # ------------------------------------------------------------------ #

        private

        def initialize(generation:, llm_settings:, extension_settings:)
          routing = llm_settings[:routing] || {}
          api     = llm_settings[:api] || {}
          # Deep-copy the extension :llm subtree so we own it immutably.
          ext_llm = extension_settings[:llm] || {}
          @ext_llm = deep_freeze_hash(ext_llm)

          @generation                      = validate_generation!(generation)
          @tier_weights                    = validate_tier_weights!(routing[:tier_weights] || {})
          @context_headroom_ppm            = resolve_context_headroom_ppm!(routing)
          @input_framing_overhead_tokens   = validate_nonneg_integer!(
            :input_framing_overhead_tokens,
            routing.fetch(:input_framing_overhead_tokens, 1_024)
          )
          @affinity_strength_bps = validate_affinity_strength_bps!(
            routing.fetch(:affinity_strength_bps, 10_000)
          )
          @maximum_attempts = validate_positive_integer!(
            :maximum_attempts,
            routing.fetch(:max_attempts, 3)
          )
          @routing_too_early_retry_after = validate_retry_after!(
            api.fetch(:routing_too_early_retry_after, 1)
          )
          @allow_body_routing_hints = validate_boolean!(
            :allow_body_routing_hints,
            routing.fetch(:allow_body_routing_hints, false)
          )
          @body_model_hint_whitelist = validate_string_list!(
            :body_model_hint_whitelist,
            routing.fetch(:body_model_hint_whitelist, [])
          )
          @body_model_hint_blacklist = validate_string_list!(
            :body_model_hint_blacklist,
            routing.fetch(:body_model_hint_blacklist, [])
          )
          @auto_routing_model_aliases = validate_string_list!(
            :auto_routing_model_aliases,
            routing.fetch(:auto_routing_model_aliases, [])
          )
          @auto_routing_model_alias_metadata = validate_alias_metadata!(
            routing.fetch(:auto_routing_model_alias_metadata, {}),
            @auto_routing_model_aliases
          )
        end

        # ------------------------------------------------------------------ #
        # Private helpers — extension settings accessors                      #
        # ------------------------------------------------------------------ #

        # Returns the provider hash (may be empty). provider_family is a Symbol.
        def ext_llm_provider(provider_family)
          @ext_llm[provider_family] || {}
        end

        # Returns the instance hash (may be empty).
        # instance_id from InstanceKey is a String; extension_settings use Symbol keys.
        def ext_llm_instance(prov_hash, instance_id)
          instances = prov_hash[:instances] || {}
          instances[instance_id.to_sym] || instances[instance_id] || {}
        end

        # One key through the lex-llm 3-level cascade (model scopes →
        # instance → provider) against the snapshot's captured extensions.llm
        # subtree. instance_id is the operator's config name.
        def cascade_value(provider_family:, instance_id:, key:, model:)
          CASCADE.resolve_from(
            llm_conf:        @ext_llm,
            provider_family: provider_family,
            instance:        instance_id,
            key:             key,
            model:           model
          )
        end

        # §9.5 — first scope whose key EXISTS wins, including explicit empty Array.
        def first_existing_policy(inst_hash, prov_hash, key)
          return inst_hash[key] if inst_hash.key?(key)
          return prov_hash[key] if prov_hash.key?(key)

          @ext_llm.key?(key) ? @ext_llm[key] : nil
        end

        # ------------------------------------------------------------------ #
        # Validation helpers                                                   #
        # ------------------------------------------------------------------ #

        def validate_generation!(val)
          return val if val.is_a?(Integer) && val.positive?

          raise ArgumentError, "generation must be a positive Integer, got #{val.inspect}"
        end

        def validate_tier_weights!(wts)
          raise ArgumentError, "tier_weights must be a Hash, got #{wts.class}" unless wts.is_a?(Hash)

          # Normalize keys to Symbol so YAML string keys work too.
          norm = wts.transform_keys { |k| k.is_a?(Symbol) ? k : k.to_sym }
          extra = norm.keys - TIER_KEYS
          raise ArgumentError, "tier_weights has unknown keys: #{extra.inspect}" if extra.any?

          TIER_KEYS.each_with_object({}) do |k, out|
            raw = norm.fetch(k) { raise ArgumentError, "tier_weights missing key #{k}" }
            raise ArgumentError, "tier_weights[#{k}] must be a nonnegative Integer, got #{raw.inspect}" unless raw.is_a?(Integer) && raw >= 0

            out[k] = raw
          end.freeze
        end

        def resolve_context_headroom_ppm!(routing)
          if routing.key?(:context_headroom)
            val = routing[:context_headroom]
            unless val.is_a?(Numeric) && !val.nan? && !val.infinite? && val.positive? && val <= 1
              raise ArgumentError,
                    "context_headroom must be a finite Numeric in (0, 1], got #{val.inspect}"
            end

            log.warn('[llm][settings_snapshot] action=deprecation key=context_headroom ' \
                     'message="context_headroom Float is deprecated; use context_headroom_ppm Integer instead"')
            ppm = (BigDecimal(val.to_s) * 1_000_000).to_i
            raise ArgumentError, "context_headroom #{val} converts to out-of-range ppm #{ppm}" unless (1..1_000_000).cover?(ppm)

            return ppm
          end

          validate_context_headroom_ppm!(routing.fetch(:context_headroom_ppm, 900_000))
        end

        def validate_context_headroom_ppm!(raw)
          return raw if raw.is_a?(Integer) && (1..1_000_000).cover?(raw)

          raise ArgumentError, "context_headroom_ppm must be an Integer in 1..1_000_000, got #{raw.inspect}"
        end

        def validate_nonneg_integer!(name, val)
          return val if val.is_a?(Integer) && val >= 0

          raise ArgumentError, "#{name} must be a nonnegative Integer, got #{val.inspect}"
        end

        def validate_positive_integer!(name, val)
          return val if val.is_a?(Integer) && val.positive?

          raise ArgumentError, "#{name} must be a positive Integer, got #{val.inspect}"
        end

        def validate_affinity_strength_bps!(raw)
          return raw if raw.is_a?(Integer) && (0..10_000).cover?(raw)

          raise ArgumentError, "affinity_strength_bps must be an Integer in 0..10_000, got #{raw.inspect}"
        end

        def validate_retry_after!(raw)
          return raw if raw.is_a?(Integer) && (1..30).cover?(raw)

          raise ArgumentError, "routing_too_early_retry_after must be an Integer in 1..30, got #{raw.inspect}"
        end

        def validate_boolean!(name, val)
          return val if [true, false].include?(val)

          raise ArgumentError, "#{name} must be true or false, got #{val.inspect}"
        end

        def validate_string_list!(name, list)
          raise ArgumentError, "#{name} must be an Array, got #{list.class}" unless list.is_a?(Array)

          list.map do |e|
            raise ArgumentError, "#{name} entries must be Strings, got #{e.inspect}" unless e.is_a?(String)

            stripped = e.strip
            raise ArgumentError, "#{name} contains blank strings" if stripped.empty?

            stripped
          end.freeze
        end

        def validate_alias_metadata!(meta, aliases)
          raise ArgumentError, "auto_routing_model_alias_metadata must be a Hash, got #{meta.class}" unless meta.is_a?(Hash)

          meta.each_with_object({}) do |(k, v), out|
            key = k.to_s
            raise ArgumentError, "alias metadata key #{k.inspect} is not a known alias" unless aliases.include?(key)
            raise ArgumentError, "alias metadata value for #{key.inspect} must be a Hash, got #{v.class}" unless v.is_a?(Hash)

            sym_v = v.transform_keys { |mk| mk.is_a?(Symbol) ? mk : mk.to_sym }
            extra = sym_v.keys - ALLOWED_ALIAS_META
            raise ArgumentError, "alias metadata for #{key.inspect} has unknown keys: #{extra.inspect}" if extra.any?

            validate_alias_meta_values!(key, sym_v)
            out[key] = sym_v.freeze
          end.freeze
        end

        def validate_alias_meta_values!(key, sym_vals)
          if sym_vals.key?(:owned_by)
            val = sym_vals[:owned_by]
            raise ArgumentError, "alias_metadata[#{key}][:owned_by] must be a nonempty String" unless val.is_a?(String) && !val.empty?
          end
          if sym_vals.key?(:created)
            val = sym_vals[:created]
            raise ArgumentError, "alias_metadata[#{key}][:created] must be a nonnegative Integer" unless val.is_a?(Integer) && val >= 0
          end
          %i[context_window max_output_tokens].each do |lim|
            next unless sym_vals.key?(lim)

            val = sym_vals[lim]
            raise ArgumentError, "alias_metadata[#{key}][#{lim}] must be a positive Integer" unless val.is_a?(Integer) && val.positive?
          end
        end

        # Recursively freeze a Hash and its Array/Hash values.
        # Strings and other scalar objects are not mutated.
        def deep_freeze_hash(obj)
          case obj
          when Hash
            obj.each_with_object({}) { |(k, v), h| h[k] = deep_freeze_hash(v) }.freeze
          when Array
            obj.map { |v| deep_freeze_hash(v) }.freeze
          else
            obj
          end
        end
      end
    end
  end
end
