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

              if client_passthrough_source?(source)
                log.info(
                  "[llm][tools] client_passthrough request_id=#{@request.id} " \
                  "tool_call_id=#{tool_call_id || 'none'} name=#{tool_name}"
                )
                log_step_debug(
                  :tool_calls,
                  :client_passthrough,
                  tool_call_id: tool_call_id || 'none',
                  tool_name:    tool_name
                )
                next
              end

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

          def client_passthrough_source?(source)
            source[:type] == :client && source[:executable] != true
          end

          def client_passthrough_tool_call?(tool_call)
            client_passthrough_source?(find_tool_source(tool_call[:name]))
          end

          def client_passthrough_tool_loop_result(result, tool_calls, round)
            result[:tool_calls] = tool_calls
            log.debug "[llm][executor] action=native_tool_loop.complete rounds=#{round} reason=client_passthrough"
            result
          end

          def normalize_tool_arguments(arguments)
            case arguments
            when nil
              {}
            when Hash
              arguments
            when String
              return {} if arguments.strip.empty?

              parsed = Legion::JSON.parse(arguments)
              parsed.is_a?(Hash) ? parsed : {}
            else
              arguments.respond_to?(:to_h) ? arguments.to_h : {}
            end
          rescue StandardError => e
            handle_exception(e, level: :debug, handled: true, operation: 'llm.pipeline.normalize_tool_arguments')
            {}
          end

          def registry_tool_sources_available?
            unless Legion::Settings::Extensions.respond_to?(:tools) &&
                   Legion::Settings::Extensions.respond_to?(:filter_tools)
              log_tool_injection_skip(:settings_extensions_unavailable)
              return false
            end

            settings_tool_count = Array(Legion::Settings::Extensions.tools).size
            if settings_tool_count.zero? && @triggered_tools.empty?
              log_tool_injection_skip(:no_settings_or_triggered_tools, settings_tool_count: settings_tool_count)
              return false
            end

            true
          end

          def log_tool_injection_skip(reason, settings_tool_count: nil)
            log.info(
              "[llm][tools][inject] action=registry_skipped request_id=#{request_log_value(:id, 'unknown')} " \
              "conversation_id=#{request_log_value(:conversation_id, 'none') || 'none'} reason=#{reason} " \
              "settings_tools=#{settings_tool_count || 'unknown'} triggered_tools=#{@triggered_tools.size} " \
              "requested_tools=#{requested_deferred_tool_names.size}"
            )
          rescue StandardError => e
            handle_exception(e, level: :debug, handled: true, operation: 'llm.pipeline.log_tool_injection_skip')
          end

          def log_native_tool_definitions(definitions)
            log.info(
              "[llm][tools][inject] action=native_tool_definitions request_id=#{request_log_value(:id, 'unknown')} " \
              "conversation_id=#{request_log_value(:conversation_id, 'none') || 'none'} provider=#{@resolved_provider || 'unknown'} " \
              "model=#{@resolved_model || 'unknown'} total=#{definitions.size} sources=#{format_tool_source_counts(definitions)} " \
              "client_request_tools=#{Array(request_log_value(:tools, [])).size} triggered_tools=#{@triggered_tools.size} " \
              "requested_tools=#{requested_deferred_tool_names.size} names=#{format_tool_names(definitions.map(&:name))}"
            )
          rescue StandardError => e
            handle_exception(e, level: :debug, handled: true, operation: 'llm.pipeline.log_native_tool_definitions')
          end

          def format_tool_source_counts(definitions)
            counts = definitions.each_with_object(Hash.new(0)) do |definition, memo|
              source = definition.respond_to?(:source) ? definition.source : {}
              key = source.is_a?(Hash) ? (source[:type] || source['type'] || :unknown) : :unknown
              memo[key] += 1
            end
            return 'none' if counts.empty?

            counts.map { |key, count| "#{key}:#{count}" }.join(',')
          end

          def format_tool_names(names, limit = 30)
            names = Array(names).map(&:to_s).reject(&:empty?)
            return 'none' if names.empty?

            visible = names.first(limit)
            suffix = names.size > limit ? ",+#{names.size - limit}more" : ''
            "#{visible.join(',')}#{suffix}"
          end

          def request_log_value(method_name, fallback)
            @request.respond_to?(method_name) ? @request.public_send(method_name) : fallback
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
