# frozen_string_literal: true

require 'legion/logging/helper'

module Legion
  module LLM
    module ProviderRegistry
      extend Legion::Logging::Helper

      @registry = {}
      @mutex = Mutex.new

      module_function

      def register(name, extension_module)
        @mutex.synchronize { @registry[name.to_sym] = extension_module }
        log.info("[llm][providers] native_registered provider=#{name}")
        extension_module
      end

      def for(name)
        @mutex.synchronize { @registry[name.to_sym] }
      end

      def available
        @mutex.synchronize { @registry.keys.dup }
      end

      def registered?(name)
        @mutex.synchronize { @registry.key?(name.to_sym) }
      end

      def reset!
        count = @mutex.synchronize { @registry.size }
        @mutex.synchronize { @registry.clear }
        log.info("[llm][providers] native_registry_reset count=#{count}")
      end
    end
  end
end
