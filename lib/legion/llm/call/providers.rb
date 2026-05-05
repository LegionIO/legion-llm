# frozen_string_literal: true

require 'legion/logging/helper'

module Legion
  module LLM
    module Call
      module Providers
        extend Legion::Logging::Helper

        module_function

        def setup
          log.debug '[llm][providers] setup.enter'
          rediscover_all_providers
          log_available
          log.debug '[llm][providers] setup.exit'
        rescue StandardError => e
          handle_exception(e, level: :error, operation: 'llm.providers.setup')
          raise
        end

        def inject_anthropic_cache_control!(opts, provider)
          resolved_provider = (provider || Legion::LLM::Settings.value(:default_provider))&.to_sym
          return unless resolved_provider == :anthropic

          caching_settings = Legion::LLM::Settings.value(:prompt_caching, default: {}) || {}
          return unless Legion::LLM::Settings.config_value(caching_settings, :enabled, true) != false

          min_tokens = Legion::LLM::Settings.config_value(caching_settings, :min_tokens) || 1024
          instructions = opts[:instructions]
          return unless instructions.is_a?(String) && instructions.length > min_tokens

          log.debug "[llm][providers] inject_anthropic_cache_control provider=#{resolved_provider} length=#{instructions.length}"
          opts[:instructions] = {
            content:       instructions,
            cache_control: { type: 'ephemeral' }
          }
        end

        # -- private helpers --------------------------------------------------

        def rediscover_all_providers
          Call::Registry.all_provider_families.each do |family|
            mod = resolve_provider_module(family)
            mod.rediscover! if mod.respond_to?(:rediscover!)
          end
        rescue StandardError => e
          handle_exception(e, level: :warn, operation: 'llm.providers.rediscover_all')
        end

        def resolve_provider_module(family)
          return nil unless defined?(Legion::Extensions::Llm)

          camel = family.to_s.split('_').map(&:capitalize).join
          Legion::Extensions::Llm.const_get(camel, false)
        rescue NameError
          nil
        end

        def log_available
          instances = Call::Registry.all_instances
          if instances.any?
            summary = instances.map { |i| "#{i[:provider]}/#{i[:instance]}" }.join(', ')
            log.info "[llm][providers] available instances=#{summary}"
          else
            log.error '[llm][providers] no providers available — no instances registered'
          end
        end
      end
    end
  end
end
