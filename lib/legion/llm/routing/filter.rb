# frozen_string_literal: true

require 'legion/logging/helper'
require 'legion/settings/helper'
require 'legion/extensions/llm/routing/records'
require 'legion/extensions/llm/capabilities'
require 'legion/extensions/llm/taxonomies'
require 'legion/extensions/llm/settings_cascade'

module Legion
  module LLM
    module Routing
      # Lane eligibility: a lane is eligible iff every applicable filter
      # passes. Each filter is a pure (lane, fact) -> pass/fail check —
      # stateless, individually RSpec-testable.
      module Filter
        include Legion::Logging::Helper
        include Legion::Settings::Helper

        # Type constraint: the lane type/modality the request asks for, or nil when unconstrained.
        def filter_type(**opts)
          type = opts[:type]
          type if type.is_a?(Symbol)
        end

        # Provider constraint: the provider the request asks for, or nil when unconstrained.
        def filter_provider(**opts)
          provider = opts[:provider]
          provider if provider.is_a?(Symbol)
        end

        # Instance constraint: the instance the request asks for, or nil when unconstrained.
        def filter_instance(**opts)
          instance = opts[:instance]
          instance if instance.is_a?(String)
        end

        # Tier constraint: the tier the request asks for, or nil when unconstrained.
        def filter_tier(**opts)
          tier = opts[:tier]
          tier if tier.is_a?(Symbol)
        end

        # Policy: model whitelist/blacklist (substring, case-insensitive); blacklist wins.
        def filter_policy(lane:, whitelist:, blacklist:, **)
          model_lc = lane.model.downcase
          return :denied if Array(blacklist).any? { |e| model_lc.include?(e.to_s.downcase) }

          wl = Array(whitelist)
          return :denied if wl.any? && wl.none? { |e| model_lc.include?(e.to_s.downcase) }

          :allowed
        end

        # Capability constraint: the capabilities the request requires, or nil when none.
        def filter_capability(**opts)
          caps = Array(opts[:capabilities]).compact
          caps.empty? ? nil : caps.freeze
        end

        # Context constraint: the required context size (tokens), or nil when unconstrained.
        def filter_context(**opts)
          context = opts[:context]
          context if context.is_a?(Integer)
        end

        # Embedding-dimension constraint: the requested dimensionality, or nil when unconstrained.
        def filter_embedding_dimensions(**opts)
          dims = opts[:embedding_dimensions]
          dims if dims.is_a?(Integer)
        end

        # Availability: the exact-instance availability state.
        def filter_availability(instance:, **)
          return :unknown if instance.nil?

          avail = instance.availability
          return :unknown if avail.nil?

          case avail.state
          when :available   then :available
          when :unavailable then :unavailable
          else                   :unknown
          end
        end

        # Fleet contract: the fleet execution contract (fleet tier only).
        def filter_fleet(lane:, **)
          return :not_applicable unless lane.tier == :fleet

          contract = lane.metadata[:fleet_execution_contract]
          if contract == 'exact_offering_v1'
            :supported
          elsif contract.nil? || contract.to_s.empty?
            :legacy
          else
            :unknown
          end
        end

        # Weight: the stored write-time weight; any zero component disables the lane.
        def filter_weight(lane:, **)
          inputs = lane.weight_inputs
          if inputs.nil? || inputs.values.any?(&:zero?)
            :disabled
          else
            :enabled
          end
        end

        # ------------------------------------------------------------------ #
        # Six lane axes (§9.7 steps 1-2, 4-6, 8 from candidate_evaluator)   #
        # ------------------------------------------------------------------ #

        CAPS    = Legion::Extensions::Llm::Capabilities
        OPS     = Legion::Extensions::Llm::Taxonomies
        CASCADE = Legion::Extensions::Llm::SettingsCascade
        private_constant :CAPS, :OPS, :CASCADE

        # §9.7 step 1 — operation axis: requested operation's coarse type vs lane type.
        # The registry publishes lanes only for supported operations, so a type
        # match is :supported and a type miss is :unsupported.
        def filter_operation(lane:, operation:, **)
          requested_type = OPS.lane_type_for(operation: operation)
          lane_type = OPS.lane_type_for(operation: lane.operation)
          lane_type == requested_type ? :supported : :unsupported
        end

        # §9.7 step 2 — provider/instance/model/tier pins.
        # :match when all configured pins equal the lane's fields.
        # :mismatch when any configured pin differs.
        def filter_pins(lane:, provider_pin: nil, instance_pin: nil, model_pin: nil, tier_constraint: nil, **)
          ik = lane.instance_key

          return :mismatch if provider_pin   && provider_pin   != ik.provider_family
          return :mismatch if instance_pin   && instance_pin   != ik.instance_id
          return :mismatch if model_pin      && model_pin      != lane.model
          return :mismatch if tier_constraint && tier_constraint != lane.tier

          :match
        end

        # §9.7 step 4 — capability reduction with the operator's enable_*
        # routing override (fail-forward decision 2).
        # All satisfied → :supported; any unknown → :unknown (highest
        # priority); any not-ready with no unknown → :unsupported.
        def evaluate_capabilities(lane:, required_capabilities:, **)
          return :supported if required_capabilities.empty?

          any_unknown     = false
          any_unsupported = false

          required_capabilities.each do |cap|
            case resolved_capability_status(lane: lane, capability: cap)
            when :unknown     then any_unknown     = true
            when :unsupported then any_unsupported = true
            end
          end

          return :unknown     if any_unknown
          return :unsupported if any_unsupported

          :supported
        end

        # §9.7 step 5 — context budget.
        # Zero budget → :not_applicable (no context requirement).
        # Authoritative limit: fits when budget <= (limit * headroom_ppm) / 1_000_000.
        # Absent or unknown context evidence → :unknown.
        def evaluate_context(lane:, budget:, **)
          return :not_applicable if budget.zero?

          ctx_ev = lane.context_evidence
          return :unknown unless ctx_ev.known?

          limit    = ctx_ev.value
          headroom = Legion::Settings[:llm][:router][:context_headroom_ppm]
          budget <= (limit * headroom) / 1_000_000 ? :fits : :rejected
        end

        # §9.7 step 6 — embedding dimensions.
        # Nil requested → :not_applicable.
        # Authoritative evidence is a sorted Array of positive Integers.
        # :match when the requested dimension appears in the supported set;
        # :rejected when the set is known but excludes the requested value.
        # Unknown evidence → :unknown.
        def evaluate_dimensions(lane:, requested_dimensions:, **)
          return :not_applicable if requested_dimensions.nil?

          dim_ev = lane.embedding_dimensions_evidence
          return :unknown unless dim_ev.known?

          Array(dim_ev.value).include?(requested_dimensions) ? :match : :rejected
        end

        # §9.7 step 8 — typed exclusions.
        # attempt_target compares (provider_family, instance_id, model) only.
        # :lane and :offering both name the 5-tuple lane id (D2).
        def filter_exclusions(lane:, exclusions:, **)
          return :clear if exclusions.empty?

          ik    = lane.instance_key
          pf    = ik.provider_family
          iid   = ik.instance_id
          model = lane.model

          excluded = exclusions.any? do |excl|
            case excl.target_kind
            when :attempt_target
              t = excl.target
              t.provider_family == pf && t.instance_id == iid && t.model == model
            when :instance
              excl.target == ik
            when :lane, :offering
              excl.target == lane.lane_id
            when :model
              excl.target == model
            when :provider
              excl.target == pf
            when :quota_domain
              qd = lane.quota_domain
              qd && excl.target == qd
            else
              false
            end
          end

          excluded ? :excluded : :clear
        end

        # ------------------------------------------------------------------ #
        # Model policy & preferred context range (cascade from ext settings) #
        # ------------------------------------------------------------------ #

        # Returns { whitelist: Array<String>, blacklist: Array<String> } using the
        # §9.5 specificity cascade: exact provider+instance → provider → global.
        # "First scope whose key EXISTS, including explicit empty Array."
        def model_policy_for(lane:, **)
          ext_llm = Legion::Settings[:extensions][:llm] || {}
          ik  = lane.instance_key
          pf  = ik.provider_family
          iid = ik.instance_id

          prov = ext_llm[pf] || {}
          instances = prov[:instances] || {}
          inst = instances[iid.to_sym] || instances[iid] || {}

          wl = first_existing_policy(inst, prov, ext_llm, :model_whitelist)
          bl = first_existing_policy(inst, prov, ext_llm, :model_blacklist)

          { whitelist: Array(wl).freeze, blacklist: Array(bl).freeze }.freeze
        end

        # Returns { min: Integer_or_nil, max: Integer_or_nil } or nil when no
        # preferred range is configured. Resolved through the lex-llm 3-level
        # cascade (provider -> instance -> model, most-specific-first) keyed
        # by the config name.
        def preferred_context_range_for(lane:, **)
          ext_llm = Legion::Settings[:extensions][:llm] || {}
          pf  = lane.instance_key.provider_family
          iid = lane.instance_key.instance_id

          min_v = CASCADE.resolve_from(
            llm_conf: ext_llm, provider_family: pf, instance: iid,
            key: :preferred_min_context_tokens, model: lane.model
          )
          max_v = CASCADE.resolve_from(
            llm_conf: ext_llm, provider_family: pf, instance: iid,
            key: :preferred_max_context_tokens, model: lane.model
          )
          return nil unless min_v || max_v

          { min: min_v, max: max_v }.freeze
        end

        private

        # Axis state for one required capability. The operator's cascaded
        # enable_<cap> for the exact instance (config name) is consulted
        # ONLY when the published evidence is :unknown.
        # Authoritative :supported/:unsupported evidence is never overridden.
        def resolved_capability_status(lane:, capability:, **)
          status = lane.capability_evidence[CAPS.canonical(capability)]&.status || :unknown
          return status unless status == :unknown

          override = CASCADE.resolve_from(
            llm_conf:        Legion::Settings[:extensions][:llm] || {},
            provider_family: lane.instance_key.provider_family,
            instance:        lane.instance_key.instance_id,
            key:             :"enable_#{capability}",
            model:           lane.model
          )
          return :supported   if override == true
          return :unsupported if override == false

          status
        end

        # §9.5 — first scope whose key EXISTS wins, including explicit empty Array.
        def first_existing_policy(inst_hash, prov_hash, ext_llm, key, **)
          return inst_hash[key] if inst_hash.key?(key)
          return prov_hash[key] if prov_hash.key?(key)

          ext_llm.key?(key) ? ext_llm[key] : nil
        end
      end
    end
  end
end
