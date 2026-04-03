# frozen_string_literal: true

require 'legion/logging/helper'

module Legion
  module LLM
    module Pipeline
      module Steps
        module TierAssigner
          module_function
          extend Legion::Logging::Helper

          DEFAULT_MAPPINGS = [
            { pattern: 'gaia:tick:*', tier: :local, intent: { cost: :minimize } },
            { pattern: 'gaia:dream:*', tier: :local, intent: { cost: :minimize } },
            { pattern: 'system:guardrails', tier: :local, intent: { cost: :minimize, capability: :basic } },
            { pattern: 'system:reflection', tier: :local, intent: { cost: :minimize, capability: :moderate } },
            { pattern: 'user:*', tier: :cloud, intent: { capability: :reasoning } }
          ].freeze

          def assign(caller:, classification:, priority:, gaia_hint:, existing_tier:, existing_intent: nil) # rubocop:disable Lint/UnusedMethodArgument
            if existing_tier
              log.debug("[llm][routing] tier_preserved tier=#{existing_tier}")
              return nil
            end

            # 1. GAIA routing hint
            recommended = gaia_hint&.dig(:data, :recommended_tier)
            if recommended
              log.info("[llm][routing] tier_assigned source=gaia tier=#{recommended}")
              return { tier: recommended.to_sym, source: :gaia }
            end

            # 2. Settings-driven role mappings
            mapping = find_role_mapping(caller)
            return mapping if mapping

            # 3. Classification-driven
            if classification && (classification[:contains_phi] || classification[:contains_pii])
              log.info('[llm][routing] tier_assigned source=classification tier=cloud')
              return { tier: :cloud, intent: { capability: :reasoning }, source: :classification }
            end

            # 4. Priority-driven
            case priority&.to_sym
            when :critical, :high
              log.info("[llm][routing] tier_assigned source=priority tier=cloud priority=#{priority}")
              { tier: :cloud, intent: { capability: :reasoning }, source: :priority }
            when :low, :background
              log.info("[llm][routing] tier_assigned source=priority tier=local priority=#{priority}")
              { tier: :local, intent: { cost: :minimize }, source: :priority }
            end
          end

          def find_role_mapping(caller)
            return nil unless caller&.dig(:requested_by, :identity)

            identity = caller[:requested_by][:identity].to_s
            tier_mappings.each do |mapping|
              next unless File.fnmatch?(mapping[:pattern], identity)

              log.info("[llm][routing] tier_mapping identity=#{identity} tier=#{mapping[:tier]}")
              return { tier: mapping[:tier]&.to_sym, intent: mapping[:intent], source: :role_mapping }
            end
            nil
          end

          def tier_mappings
            configured = Legion::Settings.dig(:llm, :routing, :tier_mappings)
            configured.nil? || configured.empty? ? DEFAULT_MAPPINGS : configured
          end
        end
      end
    end
  end
end
