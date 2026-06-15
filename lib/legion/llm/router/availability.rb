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
              detail = if %i[missing_capability capability_unconfirmed].include?(reason)
                         caps = available_capabilities(resolution)
                         missing = Capabilities.normalize(req_caps) - Capabilities.normalize(caps)
                         sources_detail = capability_sources_for(resolution)
                         " required=#{req_caps} available=#{caps} missing=#{missing}" \
                           "#{" sources=#{sources_detail}" unless sources_detail.empty?}"
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

          case discovery_state
          when :unknown
            # Cold boot: if capabilities are known (from metadata), enforce them.
            # If no capability info exists at all, remain permissive.
            # Only return :capability_unconfirmed when source data exists but
            # doesn't positively confirm the required capabilities.
            if required_capabilities.any?
              caps = available_capabilities(resolution)
              if caps.any?
                # We have capability data — enforce it
                return :missing_capability unless Capabilities.include_all?(caps, required_capabilities)
              else
                # No capability data — check if source info explicitly denies
                sources = resolution.metadata[:capability_sources] || resolution.metadata['capability_sources']
                if sources.is_a?(Hash) && sources.any? && !capabilities_confirmed_by_source?(resolution, caps, required_capabilities)
                  # Source data exists but may not confirm required caps
                  return :capability_unconfirmed
                end
                # No source data at all — remain permissive (true cold boot)
              end
            end
          when :empty
            return :provider_instance_has_no_models
          when :ok
            models = instance_models(resolution)
            return :provider_instance_has_no_models if models.empty?

            offering = find_offering(resolution, models)
            return :model_not_offered if offering.nil?

            if estimated_tokens&.positive?
              ctx = (offering[:context_length] || 0).to_i
              return :context_too_small if ctx.positive? && estimated_tokens > (ctx * context_headroom).to_i
            end
          when :unreachable, :error
            return :discovery_unavailable
          end

          if required_capabilities.any?
            caps = available_capabilities(resolution)
            if caps.any?
              return :missing_capability unless Capabilities.include_all?(caps, required_capabilities)
            elsif discovery_state == :ok
              # Discovery confirmed but no capabilities found — conservative rejection
              return :missing_capability
            end
            # When discovery is :unknown and caps are empty, remain permissive (cold boot)
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

        def discovery_status_for(resolution)
          return :unknown unless defined?(Discovery)

          discovery_settings = Legion::Settings[:llm][:discovery] || {}
          return :unknown if discovery_settings[:enabled] == false

          Discovery.discovery_status(provider: resolution.provider, instance: resolution.instance)
        end

        def available_capabilities(resolution)
          offering = find_offering(resolution)
          return Capabilities.merge(offering[:capabilities], offering['capabilities']) if discovery_status_for(resolution) == :ok && offering

          Capabilities.merge(
            offering&.dig(:capabilities),
            offering&.dig('capabilities'),
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

        # During cold boot (:unknown discovery), capabilities are only confirmed
        # when every required capability has a positive source from explicit
        # settings or metadata (not just inferred from stale registry data).
        def capabilities_confirmed_by_source?(resolution, caps, required_capabilities)
          # If we have confirmed capabilities from any source, trust them
          return true if caps.any? && Capabilities.include_all?(caps, required_capabilities)

          # Check if resolution metadata has capability_sources with positive confirmations
          sources = resolution.metadata[:capability_sources] || resolution.metadata['capability_sources']
          return false unless sources.is_a?(Hash) && sources.any?

          req_normalized = Capabilities.normalize(required_capabilities)
          req_normalized.all? do |cap|
            source_entry = sources[cap] || sources[cap.to_s]
            source_entry.is_a?(Hash) && source_entry[:value] != false
          end
        end

        def capability_sources_for(resolution)
          offering = find_offering(resolution)
          if offering
            sources = offering[:capability_sources]
            return format_sources(sources) if sources.is_a?(Hash) && sources.any?
          end

          sources = resolution.metadata[:capability_sources] || resolution.metadata['capability_sources']
          return format_sources(sources) if sources.is_a?(Hash) && sources.any?

          ''
        end

        def format_sources(sources)
          return '' unless sources.is_a?(Hash)

          sources.map { |cap, meta| "#{cap}:#{meta[:source] || meta['source'] || 'unknown'}" }.join(',')
        end
      end
    end
  end
end
