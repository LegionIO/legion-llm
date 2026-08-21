# frozen_string_literal: true

require 'legion/logging/helper'

module Legion
  module LLM
    module Inference
      module Steps
        module TierAssigner
          module_function

          extend Legion::Logging::Helper

          DEFAULT_MAPPINGS = [
            { pattern: 'gaia:tick:*', tier: :local, intent: { cost: :minimize } },
            { pattern: 'gaia:dream:*', tier: :local, intent: { cost: :minimize } },
            { pattern: 'system:guardrails', tier: :local, intent: { cost: :minimize, effort: :low } },
            { pattern: 'system:reflection', tier: :local, intent: { cost: :minimize, effort: :moderate } },
            { pattern: 'user:*', tier: :frontier, intent: { effort: :reasoning } }
          ].freeze

          def assign(caller:, classification:, priority:, gaia_hint:, existing_tier:, **)
            # Privacy classifications are hard routing constraints. They must
            # override caller-supplied tier/intent and advisory signals.
            if privacy_constrained?(classification)
              log.info('[llm][routing] tier_assigned source=classification tier=local forced=true')
              return { tier: :local, intent: { privacy: :strict }, source: :classification, forced: true }
            end

            if existing_tier
              log.debug("[llm][routing] tier_preserved tier=#{existing_tier}")
              return nil
            end

            # 1. GAIA routing hint
            recommended = nested_value(gaia_hint, :data, :tier)
            if recommended.nil? && nested_value(gaia_hint, :data, :recommended_tier)
              log.warn('[llm][routing] gaia_hint uses deprecated :recommended_tier; GAIA advisory should emit :tier')
              recommended = nested_value(gaia_hint, :data, :recommended_tier)
            end

            if recommended
              log.info("[llm][routing] tier_assigned source=gaia tier=#{recommended}")
              return { tier: recommended.to_sym, source: :gaia }
            end

            # 2. Settings-driven role mappings
            mapping = find_role_mapping(caller)
            return mapping if mapping

            # 3. Priority-driven
            case priority&.to_sym
            when :critical, :high
              log.info("[llm][routing] tier_assigned source=priority tier=frontier priority=#{priority}")
              { tier: :frontier, intent: { effort: :reasoning }, source: :priority }
            when :low, :background
              log.info("[llm][routing] tier_assigned source=priority tier=local priority=#{priority}")
              { tier: :local, intent: { cost: :minimize }, source: :priority }
            else
              log.debug(
                '[llm][steps][tier_assigner] action=no_assignment ' \
                "caller=#{caller&.dig(:requested_by, :identity) || 'none'} priority=#{priority || 'none'}"
              )
              nil
            end
          end

          def privacy_constrained?(classification)
            return false unless classification

            value(classification, :contains_phi) ||
              value(classification, :contains_pii) ||
              value(classification, :level)&.to_sym == :restricted
          end

          def find_role_mapping(caller)
            identity = nested_value(caller, :requested_by, :identity)
            return nil unless identity

            identity = identity.to_s
            tier_mappings.each do |mapping|
              next unless File.fnmatch?(value(mapping, :pattern).to_s, identity)

              tier = value(mapping, :tier)
              log.info("[llm][routing] tier_mapping identity=#{identity} tier=#{tier}")
              # L7: the assignment carries tier + intent only. The former
              # gaia:* hard provider/model pins (llm.gaia.preferred_*) were a
              # second selection domain — a settings pin that bypassed the
              # router's hint-miss fallback and could reject all traffic from
              # an identity class when the pinned model had no published lane.
              # Routing choice is Router.next_lane's alone; a preference for a
              # gaia: identity belongs in routing affinities, not here.
              return { tier: tier&.to_sym, intent: value(mapping, :intent), source: :role_mapping }
            end
            nil
          end

          def tier_mappings
            configured = Legion::Settings[:llm][:routing][:tier_mappings]
            configured.nil? || configured.empty? ? DEFAULT_MAPPINGS : configured
          end

          def value(hash, key)
            return nil unless hash.respond_to?(:key?)

            string_key = key.to_s
            return hash[string_key] if hash.key?(string_key)

            hash[key] if hash.key?(key)
          end

          def nested_value(hash, *keys)
            keys.reduce(hash) do |current, key|
              return nil unless current.respond_to?(:key?)

              value(current, key)
            end
          end
        end
      end
    end
  end
end
