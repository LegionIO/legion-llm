# frozen_string_literal: true

require 'legion/logging/helper'
require 'legion/llm/inventory/capabilities'
require_relative '../inventory'

module Legion
  module LLM
    module Router
      module Availability
        extend Legion::Logging::Helper

        module_function

        def filter_resolutions(resolutions, estimated_tokens: nil, required_capabilities: [])
          req_caps = Array(required_capabilities)
          @last_rejection_reasons = []
          resolutions.filter_map do |resolution|
            reason = rejection_reason(
              resolution,
              estimated_tokens:      estimated_tokens,
              required_capabilities: req_caps
            )
            if reason
              @last_rejection_reasons << reason
              detail = if reason == :missing_capability
                         caps = available_capabilities(resolution)
                         missing = Legion::LLM::Inventory::Capabilities.normalize(req_caps) - Legion::LLM::Inventory::Capabilities.normalize(caps)
                         " required=#{req_caps} available=#{caps} missing=#{missing}"
                       else
                         ''
                       end
              log.info "[llm][router] action=resolution_unavailable provider=#{resolution.provider} " \
                       "instance=#{resolution.instance || 'default'} model=#{resolution.model} " \
                       "reason=#{reason}#{detail}"
              next
            end
            resolution
          end
        end

        def last_rejection_reasons
          @last_rejection_reasons || []
        end

        def rejection_reason(resolution, estimated_tokens: nil, required_capabilities: [])
          # Read health from the Inventory lane (P2: lane is the single source of health truth).
          # Falls back to HealthTracker for backward-compat when no lane exists (cold-boot / no ScopedRefresher).
          matching_lanes = lane_health_for(provider: resolution.provider, instance: resolution.instance,
                                           model: resolution.model)
          if matching_lanes.any?
            return :circuit_open if matching_lanes.any? { |l| l[:health][:circuit_state] == :open }
            return :model_denied if matching_lanes.any? { |l| l[:health][:denied] }
          end
          # No lanes in Inventory means cold-boot or pre-ScopedRefresher; permit by default.

          discovery_state = discovery_status_for(resolution)
          return :instance_unresolved if resolution.instance.nil? && instance_resolution_required?(resolution, discovery_state)

          # Discovery :unreachable/:error only blocks discoverable local/fleet providers.
          # Cloud/frontier providers don't rely on discovery for availability.
          if %i[unreachable error].include?(discovery_state) &&
             Discovery::RuleGenerator::DISCOVERABLE_PROVIDERS.include?(resolution.provider&.to_sym)
            return :discovery_unavailable
          end

          # Model existence is checked against Inventory — the single source of truth
          # (settings + native-adapter static catalogs + discovery), already
          # whitelist/blacklist-filtered. The invariant: the daemon never dispatches a
          # (provider, instance, model) the catalog doesn't list — for EVERY provider,
          # cloud/frontier included. This is what blocks anthropic+qwen (qwen is not an
          # anthropic offering) and any policy-excluded model (filtered out of the
          # catalog upstream).
          #
          # Empty/nil catalog handling stays permissive so we never block on a cold
          # boot: an Inventory lookup error (nil) is permissive; an empty catalog is
          # authoritative ONLY for discoverable local/fleet providers with discovery on
          # (an empty live catalog means the instance genuinely serves nothing) —
          # otherwise an empty catalog is a not-yet-populated signal, not absence.
          discoverable = Discovery::RuleGenerator::DISCOVERABLE_PROVIDERS.include?(resolution.provider&.to_sym)
          offerings = inventory_offerings_for(resolution)
          unless offerings.nil?
            if offerings.empty?
              return :provider_instance_has_no_models if discoverable && discovery_enabled?
            else
              offering = offerings.find { |o| model_matches_offering?(resolution.model, o) }
              return :model_not_offered if offering.nil?

              if estimated_tokens&.positive?
                ctx = (offering.dig(:limits, :context_window) || offering[:context_length] || 0).to_i
                return :context_too_small if ctx.positive? && estimated_tokens > (ctx * context_headroom).to_i
              end
            end
          end

          if required_capabilities.any?
            caps = available_capabilities(resolution)
            return :missing_capability if caps.any? && !Legion::LLM::Inventory::Capabilities.include_all?(caps, required_capabilities)
          end

          nil
        rescue StandardError => e
          handle_exception(e, level: :warn, handled: true, operation: 'router.availability',
                              provider: resolution.provider)
          nil
        end

        def inventory_offerings_for(resolution)
          return nil unless defined?(Inventory)

          # Query by provider only — instance is a routing hint, not an availability gate.
          # A model being offered by ANY instance of the provider confirms availability.
          Inventory.offerings(provider: resolution.provider)
        rescue StandardError => e
          handle_exception(e, level: :warn, handled: true, operation: 'router.availability.inventory_lookup')
          nil
        end

        def model_matches_offering?(model, offering)
          offering_model = (offering[:model] || offering[:canonical_model_alias]).to_s
          model_s = model.to_s
          offering_model == model_s || offering_model.start_with?("#{model_s}:")
        end

        def discovery_status_for(resolution)
          return :unknown unless defined?(Discovery)

          return :unknown unless discovery_enabled?

          Discovery.discovery_status(provider: resolution.provider, instance: resolution.instance)
        end

        def discovery_enabled?
          llm = Legion::Settings[:llm] || {}
          discovery = llm[:discovery] || llm['discovery'] || {}
          enabled = if discovery.is_a?(Hash)
                      discovery.key?(:enabled) ? discovery[:enabled] : discovery['enabled']
                    end
          enabled != false
        end

        def available_capabilities(resolution)
          offerings = inventory_offerings_for(resolution)
          if offerings&.any?
            offering = offerings.find { |o| model_matches_offering?(resolution.model, o) }
            if offering
              return Legion::LLM::Inventory::Capabilities.merge(
                offering[:capabilities],
                offering['capabilities']
              )
            end
          end

          Legion::LLM::Inventory::Capabilities.merge(
            resolution.metadata[:model_capabilities],
            resolution.metadata['model_capabilities'],
            resolution.metadata[:capabilities],
            resolution.metadata['capabilities']
          )
        end

        def context_headroom
          routing = Legion::Settings[:llm][:routing] || {}
          (routing[:context_headroom] || 0.9).to_f
        end

        # Instance resolution is only required for discoverable local/fleet providers
        # when the live catalog shows multiple instances for that provider.
        def instance_resolution_required?(resolution, discovery_state)
          return false unless %i[ok].include?(discovery_state)
          return false unless Discovery::RuleGenerator::DISCOVERABLE_PROVIDERS.include?(resolution.provider&.to_sym)
          return false unless defined?(Legion::LLM::Inventory)

          instances = Legion::LLM::Inventory.lanes_for(provider: resolution.provider.to_sym, type: :inference)
                                            .map { |l| l[:instance_id] }.compact.uniq
          instances.size > 1
        end

        # Returns lanes from Inventory for the given (provider, instance, model) triple.
        # Used by rejection_reason to read health from the store rather than HealthTracker directly.
        # Returns [] when the live store is empty (cold boot), which triggers HealthTracker fallback.
        def lane_health_for(provider:, instance:, model:)
          return [] unless defined?(Legion::LLM::Inventory)

          lanes = Legion::LLM::Inventory.lanes_for(provider: provider, instance: instance)
          return lanes if model.nil?

          # Prefer lanes matching the exact model; fall back to all instance lanes for circuit check.
          matching = lanes.select { |l| l[:model].to_s == model.to_s }
          matching.empty? ? lanes : matching
        rescue StandardError
          []
        end
      end
    end
  end
end
