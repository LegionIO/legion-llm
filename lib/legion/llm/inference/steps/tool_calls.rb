# frozen_string_literal: true

require 'legion/logging/helper'

module Legion
  module LLM
    module Inference
      module Steps
        module ToolCalls
          include Legion::Logging::Helper

          MAX_TOOL_LOOPS = 10

          # rubocop:disable Metrics/MethodLength, Metrics/BlockLength
          def step_tool_calls
            return unless @raw_response.respond_to?(:tool_calls) && @raw_response.tool_calls&.any?

            tool_calls = @raw_response.tool_calls
            log.info(
              "[llm][tools] detected request_id=#{@request.id} " \
              "conversation_id=#{@request.conversation_id || 'none'} count=#{tool_calls.size}"
            )
            tool_calls.each do |tc|
              tool_name = tc[:name] || tc['name']
              tool_call_id = tc[:id] || tc['id']
              source = find_tool_source(tool_name)
              next unless source

              # Skip builtin tools - RubyLLM handles those
              if source[:type] == :builtin
                log.info(
                  "[llm][tools] builtin_passthrough request_id=#{@request.id} " \
                  "tool_call_id=#{tool_call_id || 'none'} name=#{tool_name}"
                )
                next
              end

              log.info(
                "[llm][tools] dispatch request_id=#{@request.id} " \
                "tool_call_id=#{tool_call_id || 'none'} name=#{tool_name} " \
                "source=#{describe_tool_source(source)} " \
                "arguments=#{summarize_tool_arguments(tc[:arguments] || tc['arguments'])}"
              )

              tool_exchange_id = Tracing.exchange_id
              result = ToolDispatcher.dispatch(
                tool_call:   tc,
                source:      source,
                exchange_id: tool_exchange_id
              )

              if @pending_tool_history
                lex_normalized = (source[:lex] || '').delete_prefix('lex-').tr('-', '_')
                runner_key     = source[:type] == :extension ? "#{lex_normalized}_#{source[:runner]}" : nil
                result_string  = result[:result].is_a?(String) ? result[:result] : Legion::JSON.dump(result[:result] || {})
                @pending_tool_history << {
                  tool_call_id:  tool_call_id,
                  pending_index: @pending_tool_history.size,
                  tool_name:     tool_name,
                  args:          tc[:arguments] || tc['arguments'] || {},
                  result:        result_string,
                  error:         result[:status] == :error,
                  runner_key:    runner_key
                }
              end

              @timeline.record(
                category: :tool, key: "tool:execute:#{tc[:name] || tc['name']}",
                exchange_id: tool_exchange_id, direction: :outbound,
                detail: "#{result[:status]} via #{source[:type]}",
                from: 'pipeline', to: "tool:#{tc[:name] || tc['name']}",
                duration_ms: result[:duration_ms],
                data: {
                  tool_call_id: tool_call_id,
                  arguments:    tc[:arguments] || tc['arguments'] || {},
                  source:       describe_tool_source(source),
                  status:       result[:status]
                }
              )

              @timeline.record(
                category: :tool, key: "tool:result:#{tc[:name] || tc['name']}",
                exchange_id: tool_exchange_id, direction: :inbound,
                detail: result[:result].to_s[0..100].to_s,
                from: "tool:#{tc[:name] || tc['name']}", to: 'pipeline',
                data: {
                  tool_call_id: tool_call_id,
                  status:       result[:status],
                  result:       result[:result]
                }
              )

              log.info(
                "[llm][tools] result request_id=#{@request.id} " \
                "tool_call_id=#{tool_call_id || 'none'} name=#{tool_name} " \
                "status=#{result[:status]} duration_ms=#{result[:duration_ms]} " \
                "preview=#{summarize_tool_result(result[:result])}"
              )
            end
          rescue StandardError => e
            @warnings << "Tool call handling error: #{e.message}"
            handle_exception(e, level: :warn, operation: 'llm.pipeline.steps.tool_calls')
          end
          # rubocop:enable Metrics/MethodLength, Metrics/BlockLength

          private

          def find_tool_source(tool_name)
            mcp_tool = @discovered_tools&.find { |t| t[:name] == tool_name }
            return mcp_tool[:source] if mcp_tool

            override = ToolDispatcher.check_override(tool_name)
            return override if override

            { type: :builtin }
          end

          def describe_tool_source(source)
            case source[:type]
            when :mcp
              "mcp:#{source[:server]}"
            when :extension
              [source[:lex], source[:runner], source[:function]].compact.join(':')
            else
              source[:type].to_s
            end
          end

          def summarize_tool_arguments(arguments)
            arguments.to_s[0, 200].inspect
          end

          def summarize_tool_result(result)
            result.to_s[0, 200].inspect
          end
        end
      end
    end
  end
end
