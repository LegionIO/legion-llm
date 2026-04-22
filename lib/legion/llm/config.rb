# frozen_string_literal: true

require 'legion/logging/helper'

module Legion
  module LLM
    module Config
      extend Legion::Logging::Helper

      module_function

      def set_defaults
        log.debug '[llm][config] set_defaults.enter'
        default_model = Legion::LLM.settings[:default_model]
        default_provider = Legion::LLM.settings[:default_provider]

        RubyLLM.configure do |c|
          c.default_model = default_model if default_model
        end

        if default_model.nil? && default_provider.nil?
          log.debug '[llm][config] set_defaults auto_configure_defaults'
          auto_configure_defaults
        end
        log.debug "[llm][config] set_defaults.exit default_model=#{Legion::LLM.settings[:default_model]} default_provider=#{Legion::LLM.settings[:default_provider]}"
      end

      def auto_configure_defaults
        log.debug '[llm][config] auto_configure_defaults.enter'
        Legion::LLM.settings[:providers].each do |provider, config|
          next unless config&.dig(:enabled)

          model = config[:default_model]
          next unless model

          Legion::LLM.settings[:default_model] = model
          Legion::LLM.settings[:default_provider] = provider
          log.info "[llm][config] auto-configured default model=#{model} provider=#{provider}"
          break
        end
        log.debug '[llm][config] auto_configure_defaults.exit'
      end
    end
  end
end
