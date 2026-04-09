# frozen_string_literal: true

require 'ruby_llm'
require 'legion/logging/helper'
require 'legion/llm/tools/interceptor'

module Legion
  module LLM
    module Tools
      class Adapter < RubyLLM::Tool
        include Legion::Logging::Helper

        MAX_TOOL_NAME_LENGTH = 64

        def initialize(tool_class)
          @tool_class = tool_class
          raw_name = tool_class.respond_to?(:tool_name) ? tool_class.tool_name : tool_class.name.to_s
          @tool_name = sanitize_tool_name(raw_name)
          @tool_desc = tool_class.respond_to?(:description) ? tool_class.description.to_s : ''
          @tool_schema = tool_class.respond_to?(:input_schema) ? tool_class.input_schema : nil
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

        def execute(**args)
          args = Interceptor.intercept(@tool_name, **args)
          log.info("[llm][tools] adapter.execute name=#{@tool_name} arguments=#{summarize_payload(args)}")
          result = @tool_class.call(**args)
          content = extract_content(result)
          log.info("[llm][tools] adapter.result name=#{@tool_name} output=#{summarize_payload(content)}")
          content
        rescue StandardError => e
          handle_exception(e, level: :warn, operation: 'llm.tools.adapter.execute', tool_name: @tool_name)
          "Tool error: #{e.message}"
        end

        private

        def extract_content(result)
          if result.respond_to?(:content) && result.content.is_a?(Array)
            result.content.filter_map { |c| c[:text] || c['text'] || c.to_s }.join("\n")
          elsif result.is_a?(Hash) && result[:content].is_a?(Array)
            result[:content].filter_map { |c| c[:text] || c['text'] }.join("\n")
          elsif result.is_a?(Hash)
            Legion::JSON.dump(result)
          elsif result.is_a?(String)
            result
          else
            result.to_s
          end
        end

        def summarize_payload(payload)
          payload.to_s[0, 200].inspect
        end

        def sanitize_tool_name(raw)
          name = raw.tr('.', '_')
          name = name.gsub(/[^a-zA-Z0-9_-]/, '')
          name = name[0, MAX_TOOL_NAME_LENGTH] if name.length > MAX_TOOL_NAME_LENGTH
          name.empty? ? "tool_#{@tool_class.object_id}" : name
        end
      end
    end
  end
end
