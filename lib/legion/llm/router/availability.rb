# frozen_string_literal: true

require 'legion/logging/helper'
require_relative '../capabilities'
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
                         missing = Capabilities.normalize(req_caps) - Capabilities.normalize(caps)
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
          state = Router.health_tracker.circuit_state(resolution.provider, instance: resolution.instance)
          return :circuit_open if state == :open
          return :model_denied if Router.health_tracker.model_denied?(provider: resolution.provider,
                                                                      model:    resolution.model,
                                                                      instance: resolution.instance)

          discovery_state = discovery_status_for(resolution)
          return :instance_unresolved if resolution.instance.nil? && instance_resolution_required?(resolution, discovery_state)

          # Discovery :unreachable/:error only blocks discoverable local/fleet providers.
          # Cloud/frontier providers don't rely on discovery for availability.
          if %i[unreachable error].include?(discovery_state) &&
             Discovery::RuleGenerator::DISCOVERABLE_PROVIDERS.include?(resolution.provider&.to_sym)
            return :discovery_unavailable
          end

          # Model existence is checked against Inventory — the single source of truth
          # (settings + native-adapter static catalogs + discovery). For discoverable
          # local/fleet providers (ollama/vllm/mlx) discovery feeds Inventory the live
          # catalog, so Inventory is AUTHORITATIVE: a model it doesn't list — including
          # a stale registry default not currently served — is rejected. This gate
          # only applies when discovery is enabled; with discovery off there is no live
          # catalog to judge against, so we stay permissive. Cloud/frontier providers
          # are never gated here (Inventory can't enumerate them as a liveness signal
          # and they don't self-report offline). An Inventory lookup error is permissive
          # (cold-boot fallback) via inventory_offerings_for returning nil.
          discoverable = Discovery::RuleGenerator::DISCOVERABLE_PROVIDERS.include?(resolution.provider&.to_sym)
          if discoverable && discovery_enabled?
            offerings = inventory_offerings_for(resolution)
            unless offerings.nil?
              return :provider_instance_has_no_models if offerings.empty?

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
            return :missing_capability if caps.any? && !Capabilities.include_all?(caps, required_capabilities)
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
          handle_exception(e, level: :debug, handled: true, operation: 'router.availability.inventory_lookup')
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
              return Capabilities.merge(
                offering[:capabilities],
                offering['capabilities']
              )
            end
          end

          Capabilities.merge(
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
        # when discovery has confirmed the provider has multiple instances.
        # During cold boot or for providers with a single instance, nil instance is fine.
        def instance_resolution_required?(resolution, discovery_state)
          return false unless %i[ok].include?(discovery_state)
          return false unless Discovery::RuleGenerator::DISCOVERABLE_PROVIDERS.include?(resolution.provider&.to_sym)

          # Only require instance if the provider actually has multiple discovered instances
          models = Array(Discovery.cached_discovered_models).select { |m| m[:provider] == resolution.provider }
          instances = models.map { |m| m[:instance] }.compact.uniq
          instances.size > 1
        end
      end
    end
  end
end
