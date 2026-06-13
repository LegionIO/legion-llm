# frozen_string_literal: true

require 'legion/logging/helper'
require_relative '../capabilities'

module Legion
  module LLM
    module Router
      module Availability
        extend Legion::Logging::Helper

        module_function

        def filter_resolutions(resolutions, estimated_tokens: nil, required_capabilities: [])
          resolutions.filter_map do |resolution|
            reason = rejection_reason(
              resolution,
              estimated_tokens:      estimated_tokens,
              required_capabilities: Array(required_capabilities)
            )
            if reason
              log.info "[llm][router] action=resolution_unavailable provider=#{resolution.provider} " \
                       "instance=#{resolution.instance || 'default'} model=#{resolution.model} reason=#{reason}"
              next
            end
            resolution
          end
        end

        def rejection_reason(resolution, estimated_tokens: nil, required_capabilities: [])
          state = Router.health_tracker.circuit_state(resolution.provider, instance: resolution.instance)
          return :circuit_open if state == :open
          return :model_denied if Router.health_tracker.model_denied?(provider: resolution.provider,
                                                                      model:    resolution.model,
                                                                      instance: resolution.instance)

          if discovery_ran_for_instance?(resolution)
            models = instance_models(resolution)
            return :provider_instance_has_no_models if models.empty?

            offering = find_offering(resolution, models)
            return :model_not_offered if offering.nil?

            if offering && estimated_tokens&.positive?
              ctx = (offering[:context_length] || 0).to_i
              return :context_too_small if ctx.positive? && estimated_tokens > (ctx * context_headroom).to_i
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

        def find_offering(resolution, models = nil)
          models ||= instance_models(resolution)
          models.find do |m|
            m[:model].to_s == resolution.model.to_s ||
              m[:model].to_s.start_with?("#{resolution.model}:")
          end
        end

        def instance_models(resolution)
          Array(Discovery.cached_discovered_models).select do |m|
            m[:provider].to_s == resolution.provider.to_s &&
              (resolution.instance.nil? || m[:instance].to_s == resolution.instance.to_s)
          end
        end

        def discovery_ran_for_instance?(resolution)
          return false unless defined?(Discovery)

          discovery_settings = Legion::Settings[:llm][:discovery] || {}
          return false if discovery_settings[:enabled] == false

          Discovery.discovery_status(provider: resolution.provider, instance: resolution.instance) != :unknown
        end

        def available_capabilities(resolution)
          offering = find_offering(resolution)
          Capabilities.merge(
            offering&.dig(:capabilities),
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
      end
    end
  end
end
