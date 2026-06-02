# frozen_string_literal: true

require 'legion/logging/helper'

module Legion
  module LLM
    module Config
      extend Legion::Logging::Helper

      module_function

      def set_defaults
        log.debug '[llm][config] set_defaults.enter'
        default_model = Legion::Settings[:llm][:default_model]
        default_provider = Legion::Settings[:llm][:default_provider]

        if default_model.nil? && default_provider.nil?
          log.debug '[llm][config] set_defaults auto_configure_defaults'
          auto_configure_defaults
        end
        log.debug "[llm][config] set_defaults.exit default_model=#{Legion::Settings[:llm][:default_model]} default_provider=#{Legion::Settings[:llm][:default_provider]}"
      end

      def auto_configure_defaults
        log.debug '[llm][config] auto_configure_defaults.enter'
        extension_providers.each do |provider, config|
          next unless config[:enabled] != false

          model = config[:default_model]
          next unless model

          Legion::Settings[:llm][:default_provider] = provider.to_sym
          Legion::Settings[:llm][:default_model] = model
          log.info "[llm][config] auto-configured default model=#{model} provider=#{provider}"
          break
        end
        log.debug '[llm][config] auto_configure_defaults.exit'
      end

      def extension_providers
        ext = Legion::Settings[:extensions]
        return ext[:llm] if ext.is_a?(Hash) && ext[:llm].is_a?(Hash)

        {}
      rescue StandardError => e
        handle_exception(e, level: :warn, handled: true, operation: 'llm.config.extension_providers')
        {}
      end
    end
  end
end
