# frozen_string_literal: true

require 'securerandom'
require 'legion/logging/helper'

module Legion
  module LLM
    module API
      module Native
        module Inference
          extend Legion::Logging::Helper

          def self.registered(app) # rubocop:disable Metrics/MethodLength,Metrics/AbcSize,Metrics/CyclomaticComplexity,Metrics/PerceivedComplexity
            log.debug('[llm][api][inference] registering POST /api/llm/inference')

            app.post '/api/llm/inference' do # rubocop:disable Metrics/BlockLength
              require_llm!
              body = parse_request_body
              validate_required!(body, :messages)

              messages        = body[:messages]
              raw_tools       = body[:tools]
              requested_tools = body[:requested_tools] || []
              model           = body[:model]
              provider        = body[:provider]
              caller_context  = body[:caller]
              conversation_id = body[:conversation_id]
              request_id      = body[:request_id] || SecureRandom.uuid

              unless messages.is_a?(Array)
                halt 400, { 'Content-Type' => 'application/json' },
                     Legion::JSON.dump({ error: { code: 'invalid_messages', message: 'messages must be an array' } })
              end

              validate_messages!(messages)

              unless raw_tools.nil? || raw_tools.is_a?(Array)
                halt 400, { 'Content-Type' => 'application/json' },
                     Legion::JSON.dump({ error: { code: 'invalid_tools', message: 'tools must be an array' } })
              end

              tools = raw_tools || []
              validate_tools!(tools) unless tools.empty?

              caller_identity = resolve_caller_identity(env)
              last_user = messages.select { |m| (m[:role] || m['role']).to_s == 'user' }.last
              prompt    = (last_user || {})[:content] || (last_user || {})['content'] || ''

              route_t0 = ::Process.clock_gettime(::Process::CLOCK_MONOTONIC)

              if defined?(Legion::Gaia) && Legion::Gaia.respond_to?(:started?) && Legion::Gaia.started? && prompt.to_s.length.positive?
                begin
                  gaia_t0 = ::Process.clock_gettime(::Process::CLOCK_MONOTONIC)
                  frame = Legion::Gaia::InputFrame.new(
                    content:      prompt,
                    channel_id:   :api,
                    content_type: :text,
                    auth_context: { identity: caller_identity },
                    metadata:     { source_type: :human_direct, salience: 0.9 }
                  )
                  Legion::Gaia.ingest(frame)
                  gaia_ms = ((::Process.clock_gettime(::Process::CLOCK_MONOTONIC) - gaia_t0) * 1000).round
                  log.debug("[llm][api][inference] action=gaia_ingest duration_ms=#{gaia_ms} request_id=#{request_id}")
                rescue StandardError => e
                  handle_exception(e, level: :warn, handled: true, operation: 'llm.api.inference.gaia_ingest', request_id: request_id)
                end
              end

              tool_declarations = tools.filter_map do |tool|
                ts = tool.respond_to?(:transform_keys) ? tool.transform_keys(&:to_sym) : tool
                build_client_tool_class(ts[:name].to_s, ts[:description].to_s, ts[:parameters] || ts[:input_schema])
              end

              log.debug("[llm][api][inference] action=tools_built client_tools=#{tool_declarations.size}")

              streaming = body[:stream] == true && request.preferred_type.to_s.include?('text/event-stream')
              normalized_caller = caller_context.respond_to?(:transform_keys) ? caller_context.transform_keys(&:to_sym) : {}
              safe_caller_fields = normalized_caller.slice(:context, :session_id, :trace_id)
              server_caller_fields = {
                source:       'api',
                path:         request.path,
                requested_by: resolve_requested_by(env, caller_identity)
              }
              effective_caller = server_caller_fields.merge(safe_caller_fields)
              caller_summary = [effective_caller[:source], effective_caller[:path]].compact.join(':')
              log.info(
                "[llm][api][inference] action=accepted request_id=#{request_id} " \
                "conversation_id=#{conversation_id || 'none'} caller=#{caller_summary} " \
                "messages=#{messages.size} client_tools=#{tools.size} requested_tools=#{Array(requested_tools).size} " \
                "requested_provider=#{provider || 'auto'} requested_model=#{model || 'auto'} stream=#{streaming}"
              )

              require 'legion/llm/inference/request' unless defined?(Legion::LLM::Inference::Request)
              require 'legion/llm/inference/executor' unless defined?(Legion::LLM::Inference::Executor)

              pipeline_request = Legion::LLM::Inference::Request.build(
                id:              request_id,
                messages:        messages,
                system:          body[:system],
                routing:         { provider: provider, model: model },
                tools:           tool_declarations,
                caller:          effective_caller,
                conversation_id: conversation_id,
                metadata:        { requested_tools: requested_tools },
                stream:          streaming,
                cache:           { strategy: :default, cacheable: true }
              )

              setup_ms = ((::Process.clock_gettime(::Process::CLOCK_MONOTONIC) - route_t0) * 1000).round
              log.debug("[llm][api][inference] action=pipeline_setup duration_ms=#{setup_ms} request_id=#{request_id}")

              executor = Legion::LLM::Inference::Executor.new(pipeline_request)

              if streaming
                content_type 'text/event-stream'
                headers 'Cache-Control'     => 'no-cache',
                        'Connection'        => 'keep-alive',
                        'X-Accel-Buffering' => 'no'

                # rubocop:disable Metrics/BlockLength
                stream do |out|
                  full_text = +''

                  executor.tool_event_handler = lambda { |event|
                    log.info("[llm][api][inference] action=tool_event type=#{event[:type]} tool=#{event[:tool_name]} id=#{event[:tool_call_id]}")
                    case event[:type]
                    when :tool_call
                      emit_sse_event(out, 'tool-call', {
                                       toolCallId: event[:tool_call_id],
                                       toolName:   event[:tool_name],
                                       args:       event[:arguments],
                                       timestamp:  Time.now.utc.iso8601
                                     })
                    when :tool_result
                      emit_sse_event(out, 'tool-result', {
                                       toolCallId: event[:tool_call_id],
                                       toolName:   event[:tool_name],
                                       result:     event[:result],
                                       timestamp:  Time.now.utc.iso8601
                                     })
                    when :tool_error
                      emit_sse_event(out, 'tool-error', {
                                       toolCallId: event[:tool_call_id],
                                       toolName:   event[:tool_name],
                                       result:     event[:error],
                                       status:     'error',
                                       timestamp:  Time.now.utc.iso8601
                                     })
                    end
                  }

                  pipeline_response = executor.call_stream do |chunk|
                    text = chunk.respond_to?(:content) ? chunk.content.to_s : chunk.to_s
                    next if text.empty?

                    full_text << text
                    emit_sse_event(out, 'text-delta', { delta: text })
                  end

                  emit_timeline_tool_events(out, pipeline_response, skip_tool_results: !executor.tool_event_handler.nil?)

                  enrichments = pipeline_response.enrichments
                  emit_sse_event(out, 'enrichment', enrichments) if enrichments.is_a?(Hash) && !enrichments.empty?

                  routing = pipeline_response.routing || {}
                  tokens = pipeline_response.tokens || {}
                  emit_sse_event(out, 'done', {
                                   request_id:      request_id,
                                   content:         full_text,
                                   model:           (routing[:model] || routing['model']).to_s,
                                   input_tokens:    token_value(tokens, :input),
                                   output_tokens:   token_value(tokens, :output),
                                   tool_calls:      extract_tool_calls(pipeline_response),
                                   conversation_id: pipeline_response.conversation_id
                                 })

                  log.info(
                    "[llm][api][inference] action=completed request_id=#{request_id} " \
                    "conversation_id=#{pipeline_response.conversation_id || conversation_id || 'none'} " \
                    "provider=#{routing[:provider] || routing['provider'] || 'unknown'} " \
                    "model=#{routing[:model] || routing['model'] || 'unknown'} " \
                    "input_tokens=#{token_value(tokens, :input) || 0} output_tokens=#{token_value(tokens, :output) || 0} " \
                    "tool_calls=#{extract_tool_calls(pipeline_response).size} " \
                    "tool_executions=#{Array(pipeline_response.timeline).count { |event| event[:key].to_s.start_with?('tool:execute:') }} " \
                    "stop_reason=#{pipeline_response.stop&.dig(:reason) || 'unknown'} stream=true"
                  )
                rescue StandardError => e
                  handle_exception(e, level: :error, handled: false, operation: 'llm.api.inference.stream', request_id: request_id)
                  emit_sse_event(out, 'error', { code: 'stream_error', message: e.message })
                end
                # rubocop:enable Metrics/BlockLength
              else
                exec_t0 = ::Process.clock_gettime(::Process::CLOCK_MONOTONIC)
                pipeline_response = executor.call
                exec_ms = ((::Process.clock_gettime(::Process::CLOCK_MONOTONIC) - exec_t0) * 1000).round
                log.debug("[llm][api][inference] action=executor_call duration_ms=#{exec_ms} request_id=#{request_id}")
                raw_msg = pipeline_response.message
                content = raw_msg.is_a?(Hash) ? (raw_msg[:content] || raw_msg['content']) : raw_msg.to_s
                routing = pipeline_response.routing || {}
                tokens = pipeline_response.tokens || {}
                tool_calls = extract_tool_calls(pipeline_response)

                log.info(
                  "[llm][api][inference] action=completed request_id=#{request_id} " \
                  "conversation_id=#{pipeline_response.conversation_id || conversation_id || 'none'} " \
                  "provider=#{routing[:provider] || routing['provider'] || 'unknown'} " \
                  "model=#{routing[:model] || routing['model'] || 'unknown'} " \
                  "input_tokens=#{token_value(tokens, :input) || 0} output_tokens=#{token_value(tokens, :output) || 0} " \
                  "tool_calls=#{tool_calls.size} " \
                  "tool_executions=#{Array(pipeline_response.timeline).count { |event| event[:key].to_s.start_with?('tool:execute:') }} " \
                  "stop_reason=#{pipeline_response.stop&.dig(:reason) || 'unknown'} stream=false"
                )

                json_response({
                                request_id:      request_id,
                                content:         content,
                                tool_calls:      tool_calls,
                                stop_reason:     pipeline_response.stop&.dig(:reason)&.to_s,
                                model:           (routing[:model] || routing['model']).to_s,
                                input_tokens:    token_value(tokens, :input),
                                output_tokens:   token_value(tokens, :output),
                                conversation_id: pipeline_response.conversation_id
                              }, status_code: 200)
              end
            rescue Legion::LLM::AuthError => e
              handle_exception(e, level: :error, handled: true, operation: 'llm.api.inference.auth', request_id: request_id)
              json_error('auth_error', e.message, status_code: 401)
            rescue Legion::LLM::RateLimitError => e
              handle_exception(e, level: :error, handled: true, operation: 'llm.api.inference.rate_limit', request_id: request_id)
              json_error('rate_limit', e.message, status_code: 429)
            rescue Legion::LLM::TokenBudgetExceeded => e
              handle_exception(e, level: :error, handled: true, operation: 'llm.api.inference.budget', request_id: request_id)
              json_error('token_budget_exceeded', e.message, status_code: 413)
            rescue Legion::LLM::ProviderDown, Legion::LLM::ProviderError => e
              handle_exception(e, level: :error, handled: true, operation: 'llm.api.inference.provider', request_id: request_id)
              json_error('provider_error', e.message, status_code: 502)
            rescue StandardError => e
              handle_exception(e, level: :error, handled: false, operation: 'llm.api.inference', request_id: request_id)
              json_error('inference_error', e.message, status_code: 500)
            end

            log.debug('[llm][api][inference] POST /api/llm/inference registered')
          end
        end
      end
    end
  end
end
