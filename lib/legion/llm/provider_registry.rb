# frozen_string_literal: true

module Legion
  module LLM
    module ProviderRegistry
      @registry = {}
      @mutex = Mutex.new

      module_function

      def register(name, extension_module)
        @mutex.synchronize { @registry[name.to_sym] = extension_module }
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
        @mutex.synchronize { @registry.clear }
      end
    end
  end
end
