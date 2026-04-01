# frozen_string_literal: true

require 'ruby_llm'

module Legion
  module LLM
    module Pipeline
      class McpToolAdapter < RubyLLM::Tool
        def initialize(mcp_tool_class)
          @mcp_tool_class = mcp_tool_class
          raw_name = mcp_tool_class.respond_to?(:tool_name) ? mcp_tool_class.tool_name : mcp_tool_class.name.to_s
          @tool_name = raw_name.tr('.', '_')
          @tool_desc = mcp_tool_class.respond_to?(:description) ? mcp_tool_class.description.to_s : ''
          @tool_schema = mcp_tool_class.respond_to?(:input_schema) ? mcp_tool_class.input_schema : nil
          super()
        end

        def name
          @tool_name
        end

        def description
          @tool_desc
        end

        def params_schema
          return @params_schema if defined?(@params_schema)

          @params_schema = (RubyLLM::Utils.deep_stringify_keys(@tool_schema) if @tool_schema.is_a?(Hash))
        end

        def execute(**)
          result = @mcp_tool_class.call(**)
          if result.is_a?(Hash) && result[:content]
            result[:content].map { |c| c[:text] || c['text'] }.compact.join("\n")
          elsif result.is_a?(String)
            result
          else
            result.to_s
          end
        rescue StandardError => e
          "Tool error: #{e.message}"
        end
      end
    end
  end
end
