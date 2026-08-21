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
              # G3: @raw_response.tool_calls is Array<Canonical::ToolCall> —
              # member reads only (the former tc[:name] Hash indexing raised
              # NoMethodError on canonical objects and was swallowed by the
              # step-level rescue, silently disabling this step).
              tool_name = tc.name
              tool_call_id = tc.id
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
              log_tool_call_dispatch(tool_call_id, tool_name, source, tc.arguments)
              # The dispatcher is a daemon-internal Hash-consumer (registry/
              # extension/mcp execution) — the canonical tool call projects to
              # its wire shape at this boundary (member reads; G3).
              result = ToolDispatcher.dispatch(
                tool_call:   { id: tool_call_id, name: tool_name, arguments: tc.arguments },
                source:      source,
                exchange_id: tool_exchange_id
              )

              if @pending_tool_history
                lex_normalized = (source[:lex] || source[:extension] || '').delete_prefix('lex-').tr('-', '_')
                runner_key     = source[:type] == :extension ? "#{lex_normalized}_#{source[:runner]}" : nil
                result_string  = result[:result].is_a?(String) ? result[:result] : Legion::JSON.dump(result[:result] || {})
                @pending_tool_history_mutex.synchronize do
                  @pending_tool_history << {
                    tool_call_id:  tool_call_id,
                    pending_index: @pending_tool_history.size,
                    tool_name:     tool_name,
                    args:          tc.arguments,
                    result:        result_string,
                    error:         result[:status] == :error,
                    runner_key:    runner_key
                  }
                end
              end

              # :source is the display string (native SSE surface);
              # :source_type is the canonical dispatch-type enum consumed by
              # the response-exit reconstruction (G3).
              @timeline.record(
                category: :tool, key: "tool:execute:#{tool_name}",
                exchange_id: tool_exchange_id, direction: :outbound,
                detail: "#{result[:status]} via #{source[:type]}",
                from: 'pipeline', to: "tool:#{tool_name}",
                duration_ms: result[:duration_ms],
                data: {
                  tool_call_id: tool_call_id,
                  arguments:    tc.arguments,
                  source:       describe_tool_source(source),
                  source_type:  source[:type]&.to_sym,
                  status:       result[:status]
                }
              )

              @timeline.record(
                category: :tool, key: "tool:result:#{tool_name}",
                exchange_id: tool_exchange_id, direction: :inbound,
                detail: result[:result].to_s[0, Legion::Settings[:llm][:tools][:result_detail_chars]].to_s,
                from: "tool:#{tool_name}", to: 'pipeline',
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

          private

          def find_tool_source(tool_name)
            tool_key = tool_name.to_s

            native_source = @native_tool_source_map&.[](tool_key) || @native_tool_source_map&.[](tool_name)
            if native_source
              registry_tool = @injected_tool_map&.[](tool_key) || @injected_tool_map&.[](tool_name)
              if native_source[:type] == :registry && registry_tool
                log.debug "[llm][tool_calls] action=source_resolved tool=#{tool_key} source=native_registry"
                return native_source.merge(tool_class: registry_tool)
              end

              log.debug "[llm][tool_calls] action=source_resolved tool=#{tool_key} source=native_map type=#{native_source[:type]}"
              return native_source
            end

            mcp_tool = @discovered_tools&.find { |t| t[:name].to_s == tool_key }
            if mcp_tool
              log.debug "[llm][tool_calls] action=source_resolved tool=#{tool_key} source=mcp server=#{mcp_tool[:source][:server]}"
              return mcp_tool[:source]
            end

            registry_tool = @injected_tool_map&.[](tool_key) || @injected_tool_map&.[](tool_name)
            if registry_tool
              log.debug "[llm][tool_calls] action=source_resolved tool=#{tool_key} source=injected_registry"
              return { type: :registry, tool_class: registry_tool }
            end

            override = ToolDispatcher.check_override(tool_key)
            if override
              log.debug "[llm][tool_calls] action=source_resolved tool=#{tool_key} source=override type=#{override[:type]}"
              return override
            end

            log.debug "[llm][tool_calls] action=source_resolved tool=#{tool_key} source=builtin"
            { type: :builtin }
          end

          def client_passthrough_source?(source)
            source[:type] == :client
          end

          def client_passthrough_tool_call?(tool_call)
            client_passthrough_source?(find_tool_source(tool_call_value(tool_call, :name)))
          end

          def client_passthrough_tool_loop_result(result, tool_calls, round)
            # DO NOT overwrite result[:tool_calls] with just client tools.
            # The provider response already contains ALL tool calls (LegionIO + client).
            # The translator needs to see both:
            #   - LegionIO tools with results → server_tool_use + server_tool_result
            #   - Client tools without results → tool_use (passthrough)

            # Populate :result on LegionIO tool calls from @pending_tool_history.
            # These tools already executed server-side, but the result hash
            # doesn't have the results yet. Without this, format_stop_reason
            # sees LegionIO tools with nil results → returns 'pause_turn' →
            # causes Claude Code to auto-send a follow-up → duplicate responses.
            updated_tool_calls = Array(tool_call_value(result, :tool_calls)).map do |tc|
              next tc if client_passthrough_tool_call?(tc)

              tc_id = tool_call_value(tc, :id)
              tc_name = tool_call_value(tc, :name)
              entry = @pending_tool_history&.find { |e| e[:tool_call_id] == tc_id || e[:tool_name] == tc_name }
              next tc unless entry && entry[:result]

              tc = tool_call_with_execution_result(tc, entry)
              log.debug("[llm][tool_loop] action=populate_legionio_result tool=#{tc_name} " \
                        "tc_id=#{tc_id} result_length=#{entry[:result].to_s.length}")
              tc
            end
            result = response_with_tool_calls(result, updated_tool_calls)

            # Only emit events for client passthrough tools here.
            tool_calls.each do |tool_call|
              next unless client_passthrough_tool_call?(tool_call)

              normalized = normalize_native_tool_call(tool_call)
              emit_tool_call_event(normalized, round)
              emit_tool_result_event(
                Executor::ToolResultEvent.new(
                  result:       "Passthrough to client: #{normalized[:name]}",
                  tool_call_id: normalized[:id],
                  tool_name:    normalized[:name],
                  started_at:   Time.now,
                  status:       :success
                )
              )
            end
            log.debug "[llm][executor] action=native_tool_loop.complete rounds=#{round} reason=client_passthrough"
            result
          end

          # G3: the tool loop operates on canonical objects only — member
          # reads, no Hash-index fallback (the fallback branch was the
          # split-world seam).
          def tool_call_value(tool_call, field)
            tool_call.public_send(field)
          end

          def response_with_tool_calls(result, tool_calls)
            result.with(tool_calls: tool_calls)
          end

          def tool_call_with_execution_result(tool_call, entry)
            typed_call = entry[:typed_call]
            source = typed_call&.source || tool_call_value(tool_call, :source)
            # 0.8.0 core: Canonical::ToolCall.source is the closed dispatch-type
            # enum, not the legacy routing hash. The routing details
            # (tool_class/lex/runner) were consumed at dispatch time; the
            # canonical record keeps only the type (mirrors
            # API::DebugFormats.canonical_tool_call).
            source = canonical_source_symbol(source) if tool_call.is_a?(Legion::Extensions::Llm::Canonical::ToolCall)
            status = entry[:error] ? :error : :success
            duration_ms = typed_call&.duration_ms || tool_call_value(tool_call, :duration_ms)

            if tool_call.respond_to?(:with_result)
              base = tool_call.respond_to?(:with) ? tool_call.with(source: source) : tool_call
              return base.with_result(
                result:      entry[:result],
                status:      status,
                duration_ms: duration_ms,
                finished_at: typed_call&.finished_at
              )
            end

            if tool_call.respond_to?(:with)
              return tool_call.with(
                source:      source,
                status:      status,
                duration_ms: duration_ms,
                result:      entry[:result],
                error:       (entry[:result] if entry[:error])
              )
            end

            tool_call.merge(
              result:      entry[:result],
              'result'    => entry[:result],
              source:      source,
              status:      status,
              duration_ms: duration_ms,
              error:       (entry[:result] if entry[:error])
            ).compact
          end

          # Legacy dispatch-routing source hash → canonical dispatch-type enum.
          # Non-hash sources (already-canonical symbols, nil) pass through.
          # :builtin (provider-owned passthrough — the daemon never executes
          # it) maps to :client: the only enum bucket whose consumer semantics
          # (non-server-executed, client-actionable) match a passthrough tool.
          # Without the mapping the value would fail the canonical source enum
          # validation at the response exit.
          def canonical_source_symbol(source)
            sym = source.is_a?(Hash) ? (source[:type] || source['type'])&.to_sym : source
            return :client if sym == :builtin

            sym
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
            handle_exception(e, level: :warn, handled: true, operation: 'llm.pipeline.log_tool_injection_skip')
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
            handle_exception(e, level: :warn, handled: true, operation: 'llm.pipeline.log_native_tool_definitions')
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

          def format_tool_names(names, limit = Legion::Settings[:llm][:tools][:name_log_limit])
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
              [source[:lex] || source[:extension], source[:runner], source[:function]].compact.join(':')
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
            if result[:status] == :error
              log.warn(
                "[llm][tool_calls] action=tool_call_failed request_id=#{@request.id} " \
                "tool_call_id=#{tool_call_id || 'none'} name=#{tool_name} " \
                "duration_ms=#{result[:duration_ms]} " \
                "error=#{Legion::LLM::Tools::Dispatcher.error_log_detail(result)}"
              )
            else
              log.info(
                "[llm][tools] result request_id=#{@request.id} " \
                "tool_call_id=#{tool_call_id || 'none'} name=#{tool_name} " \
                "status=#{result[:status]} duration_ms=#{result[:duration_ms]} " \
                "result_class=#{result[:result].class} result_chars=#{result_size(result[:result])}"
              )
            end
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
