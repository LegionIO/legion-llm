# frozen_string_literal: true

module Legion
  module LLM
    module Pipeline
      module Steps
        module ToolCalls
          MAX_TOOL_LOOPS = 10

          def step_tool_calls
            return unless @raw_response.respond_to?(:tool_calls) && @raw_response.tool_calls&.any?

            tool_calls = @raw_response.tool_calls
            tool_calls.each do |tc|
              source = find_tool_source(tc[:name] || tc['name'])
              next unless source

              # Skip builtin tools - RubyLLM handles those
              next if source[:type] == :builtin

              tool_exchange_id = Tracing.exchange_id
              result = ToolDispatcher.dispatch(
                tool_call:   tc,
                source:      source,
                exchange_id: tool_exchange_id
              )

              @timeline.record(
                category: :tool, key: "tool:execute:#{tc[:name] || tc['name']}",
                exchange_id: tool_exchange_id, direction: :outbound,
                detail: "#{result[:status]} via #{source[:type]}",
                from: 'pipeline', to: "tool:#{tc[:name] || tc['name']}",
                duration_ms: result[:duration_ms]
              )

              @timeline.record(
                category: :tool, key: "tool:result:#{tc[:name] || tc['name']}",
                exchange_id: tool_exchange_id, direction: :inbound,
                detail: result[:result].to_s[0..100].to_s,
                from: "tool:#{tc[:name] || tc['name']}", to: 'pipeline',
                data: { status: result[:status] }
              )
            end
          rescue StandardError => e
            @warnings << "Tool call handling error: #{e.message}"
          end

          private

          def find_tool_source(tool_name)
            mcp_tool = @discovered_tools&.find { |t| t[:name] == tool_name }
            return mcp_tool[:source] if mcp_tool

            override = ToolDispatcher.check_override(tool_name)
            return override if override

            { type: :builtin }
          end
        end
      end
    end
  end
end
