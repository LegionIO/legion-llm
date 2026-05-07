# frozen_string_literal: true

require 'legion/logging/helper'
require_relative 'logging'

module Legion
  module LLM
    module Inference
      module Steps
        module ToolCalls
          include Legion::Logging::Helper
          include Steps::Logging

          MAX_TOOL_LOOPS = 10

          # rubocop:disable Metrics/MethodLength, Metrics/BlockLength
          def step_tool_calls
            unless @raw_response.respond_to?(:tool_calls) && @raw_response.tool_calls&.any?
              log_step_debug(:tool_calls, :skipped, reason: :no_tool_calls)
              return
            end

            tool_calls = @raw_response.tool_calls
            log_step_debug(:tool_calls, :start, tool_call_count: tool_calls.size)
            log.info(
              "[llm][tools] detected request_id=#{@request.id} " \
              "conversation_id=#{@request.conversation_id || 'none'} count=#{tool_calls.size}"
            )
            tool_calls.each do |tc|
              tool_name = tc[:name] || tc['name']
              tool_call_id = tc[:id] || tc['id']
              source = find_tool_source(tool_name)
              next unless source

              # Skip builtin tools; native providers handle provider-owned tools.
              if source[:type] == :builtin
                log.info(
                  "[llm][tools] builtin_passthrough request_id=#{@request.id} " \
                  "tool_call_id=#{tool_call_id || 'none'} name=#{tool_name}"
                )
                next
              end

              tool_exchange_id = Tracing.exchange_id
              log_tool_call_dispatch(tool_call_id, tool_name, source, tc[:arguments] || tc['arguments'])
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

              log_tool_call_result(tool_call_id, tool_name, result)
            end
          rescue StandardError => e
            @warnings << "Tool call handling error: #{e.message}"
            handle_exception(e, level: :warn, operation: 'llm.pipeline.steps.tool_calls')
          end
          # rubocop:enable Metrics/MethodLength, Metrics/BlockLength

          private

          def find_tool_source(tool_name)
            tool_key = tool_name.to_s

            native_source = @native_tool_source_map&.[](tool_key) || @native_tool_source_map&.[](tool_name)
            if native_source
              registry_tool = @injected_tool_map&.[](tool_key) || @injected_tool_map&.[](tool_name)
              return native_source.merge(tool_class: registry_tool) if native_source[:type] == :registry && registry_tool

              return native_source
            end

            mcp_tool = @discovered_tools&.find { |t| t[:name].to_s == tool_key }
            return mcp_tool[:source] if mcp_tool

            registry_tool = @injected_tool_map&.[](tool_key) || @injected_tool_map&.[](tool_name)
            return { type: :registry, tool_class: registry_tool } if registry_tool

            override = ToolDispatcher.check_override(tool_key)
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

          def log_tool_call_dispatch(tool_call_id, tool_name, source, arguments)
            source_description = describe_tool_source(source)
            log.info(
              "[llm][tools] dispatch request_id=#{@request.id} " \
              "tool_call_id=#{tool_call_id || 'none'} name=#{tool_name} " \
              "source=#{source_description} argument_chars=#{argument_size(arguments)}"
            )
            log_step_debug(
              :tool_calls,
              :dispatch,
              tool_call_id: tool_call_id || 'none',
              tool_name:    tool_name,
              source:       source_description
            )
          end

          def log_tool_call_result(tool_call_id, tool_name, result)
            log.info(
              "[llm][tools] result request_id=#{@request.id} " \
              "tool_call_id=#{tool_call_id || 'none'} name=#{tool_name} " \
              "status=#{result[:status]} duration_ms=#{result[:duration_ms]} " \
              "result_class=#{result[:result].class} result_chars=#{result_size(result[:result])}"
            )
            log_step_debug(
              :tool_calls,
              :result,
              tool_call_id: tool_call_id || 'none',
              tool_name:    tool_name,
              status:       result[:status],
              duration_ms:  result[:duration_ms]
            )
          end

          def argument_size(arguments)
            arguments.to_s.length
          end

          def result_size(result)
            result.to_s.length
          end
        end
      end
    end
  end
end
