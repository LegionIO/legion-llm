# frozen_string_literal: true

module Legion
  module LLM
    module ToolRegistry
      @tools = []
      @mutex = Mutex.new

      class << self
        def register(tool_class)
          @mutex.synchronize do
            @tools << tool_class unless @tools.include?(tool_class)
          end
        end

        def tools
          @mutex.synchronize { @tools.dup }
        end

        def clear
          @mutex.synchronize { @tools.clear }
        end
      end
    end
  end
end
