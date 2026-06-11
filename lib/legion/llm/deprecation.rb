# frozen_string_literal: true

require 'legion/logging/helper'

module Legion
  module LLM
    module Deprecation
      extend Legion::Logging::Helper

      @warned = {}
      @mutex = Mutex.new

      class << self
        def warn_once(method_name, replacement:)
          return if warned?(method_name)

          @mutex.synchronize { @warned[method_name] = true }
          log.warn(
            "[llm][deprecation] #{method_name} is deprecated and will be removed in the next release. " \
            "Use #{replacement} instead. All callers must migrate before deletion."
          )
        end

        def warned?(method_name)
          @mutex.synchronize { @warned[method_name] == true }
        end

        def reset!
          @mutex.synchronize { @warned.clear }
        end
      end
    end
  end
end
