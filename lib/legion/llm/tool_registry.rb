# frozen_string_literal: true

require 'legion/logging/helper'

module Legion
  module LLM
    module ToolRegistry
      extend Legion::Logging::Helper

      @tools = []
      @mutex = Mutex.new

      class << self
        def register(tool_class)
          registered = @mutex.synchronize do
            next false if @tools.include?(tool_class)

            @tools << tool_class
            true
          end
          if registered
            log.info("[llm][tools] registered class=#{tool_class}")
          else
            log.debug("[llm][tools] already_registered class=#{tool_class}")
          end
        end

        def tools
          @mutex.synchronize { @tools.dup }
        end

        def clear
          count = @mutex.synchronize { @tools.size }
          @mutex.synchronize { @tools.clear }
          log.info("[llm][tools] registry_cleared count=#{count}")
        end
      end
    end
  end
end
