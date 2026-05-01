# frozen_string_literal: true

require 'legion/logging/helper'

module Legion
  module LLM
    module Call
      module Registry
        extend Legion::Logging::Helper

        # @registry structure: { provider_sym => { instance_sym => adapter } }
        @registry = {}
        @mutex = Mutex.new

        module_function

        def register(name, extension_module, instance: :default)
          provider = name.to_sym
          inst = instance.to_sym
          @mutex.synchronize do
            @registry[provider] ||= {}
            @registry[provider][inst] = extension_module
          end
          log.info("[llm][registry] registered provider=#{provider} instance=#{inst}")
          extension_module
        end

        def for(name, instance: nil)
          provider = name.to_sym
          @mutex.synchronize do
            instances = @registry[provider]
            return nil unless instances

            if instance
              instances[instance.to_sym]
            else
              instances[:default] || instances.values.first
            end
          end
        end

        def instances_for(name)
          provider = name.to_sym
          @mutex.synchronize { (@registry[provider] || {}).dup }
        end

        def available
          @mutex.synchronize { @registry.keys.dup }
        end

        def registered?(name, instance: nil)
          provider = name.to_sym
          @mutex.synchronize do
            return false unless @registry.key?(provider)
            return true unless instance

            @registry[provider].key?(instance.to_sym)
          end
        end

        def reset!
          @mutex.synchronize do
            count = @registry.values.sum(&:size)
            @registry.clear
            log.info("[llm][registry] reset count=#{count}")
          end
        end
      end
    end
  end
end
