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

        # -- private helpers --------------------------------------------------

        def rediscover_all_providers
          loaded_provider_modules.each { |provider_module| rediscover_provider_module(provider_module) }
        rescue StandardError => e
          handle_exception(e, level: :warn, operation: 'llm.providers.rediscover_all')
        end

        def loaded_provider_modules
          return [] unless defined?(Legion::Extensions::Llm)

          Legion::Extensions::Llm.constants(false).filter_map do |const_name|
            mod = Legion::Extensions::Llm.const_get(const_name, false)
            provider_module?(mod) ? mod : nil
          rescue NameError => e
            log.debug "[llm][providers] action=discover_provider_modules const=#{const_name} error=#{e.class} — #{e.message}"
            nil
          end
        end

        def provider_module?(mod)
          mod.is_a?(Module) &&
            mod.const_defined?(:PROVIDER_FAMILY, false) &&
            mod.respond_to?(:provider_class) &&
            mod.respond_to?(:discover_instances)
        end

        def rediscover_provider_module(provider_module)
          family = provider_module::PROVIDER_FAMILY.to_sym
          aliases = provider_aliases(provider_module)
          ([family] + aliases).each { |provider| Call::Registry.deregister_provider(provider) }

          provider_module.discover_instances.each do |instance_id, config|
            register_provider_instance(provider_module, family, aliases, instance_id, config)
          end
        rescue StandardError => e
          handle_exception(e, level: :warn, handled: true,
                              operation: 'llm.providers.rediscover_provider',
                              provider: safe_provider_family(provider_module))
        end

        def register_provider_instance(provider_module, family, aliases, instance_id, config)
          normalized_config = normalize_instance_config(config)
          return if normalized_config[:enabled] == false

          registry_config = adapter_instance_config(normalized_config, instance_id)
          metadata = instance_metadata(normalized_config)
          adapter = Call::LexLLMAdapter.new(family, provider_module.provider_class, instance_config: registry_config)

          Call::Registry.register(family, adapter, instance: instance_id, metadata: metadata)
          aliases.each do |provider_alias|
            Call::Registry.register(provider_alias, adapter, instance: instance_id, metadata: metadata)
          end
        end

        def provider_aliases(provider_module)
          return [] unless provider_module.respond_to?(:provider_aliases)

          Array(provider_module.provider_aliases).compact.map(&:to_sym)
        end

        def normalize_instance_config(config)
          config.to_h.transform_keys { |key| key.respond_to?(:to_sym) ? key.to_sym : key }
        end

        def adapter_instance_config(config, instance_id)
          config.except(:tier).tap do |registry_config|
            registry_config[:instance_id] ||= instance_id
          end
        end

        def instance_metadata(config)
          meta = { tier: config[:tier], capabilities: config[:capabilities] || [] }
          meta[:default_model] = config[:default_model] if config[:default_model]
          meta[:source] = config[:source] if config[:source]
          meta[:credential_fingerprint] = config[:credential_fingerprint] if config[:credential_fingerprint]
          meta
        end

        def safe_provider_family(provider_module)
          return nil unless provider_module&.const_defined?(:PROVIDER_FAMILY, false)

          provider_module::PROVIDER_FAMILY
        rescue StandardError => e
          log.debug "[llm][providers] action=safe_provider_family error=#{e.class} — #{e.message}"
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
