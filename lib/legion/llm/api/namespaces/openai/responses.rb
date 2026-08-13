# frozen_string_literal: true

require 'legion/logging/helper'
require 'legion/llm/token_estimation'
require 'legion/llm/api/namespaces/helpers'
require 'legion/llm/api/client_translators/openai_responses'
require 'legion/llm/api/stream_assembler'
require 'legion/llm/api/debug_formats'

module Legion
  module LLM
    module API
      module Namespaces
        module OpenAI
          # Sinatra extension for /v1/responses — parse → translate → execute → respond.
          # All translation lives in API::ClientTranslators::OpenAIResponses.
          module Responses
            extend Legion::Logging::Helper

            def self.registered(app) # rubocop:disable Metrics/AbcSize
              log.debug('[llm][api][namespaces][openai][responses] registering routes')

              app.post '/v1/responses' do
                require_llm!
                validate_legion_routing_headers!(env)
                request_started_at = ::Process.clock_gettime(::Process::CLOCK_MONOTONIC)
                body = parse_request_body

                input = body[:input]
                unless input.is_a?(Array) || input.is_a?(String)
                  return openai_error('input is required (string or array)',
                                      type: 'invalid_request_error', status_code: 400)
                end

                translator = Legion::LLM::API::ClientTranslators::OpenAIResponses.new
                canonical_request = translator.parse_request(body, env)
                # Default reasoning.summary to 'auto' when the caller asked
                # for reasoning but didn't pin a summary mode — OpenAI's
                # /v1/responses lane omits reasoning content otherwise (B3).
                body = translator.ensure_reasoning_summary(body)
                request_id = canonical_request.id
                model = body[:model] || Legion::Settings[:llm][:default_model] || 'default'
                streaming = canonical_request.stream

                inference_request = translator.build_inference_request(
                  canonical_request,
                  request_id:    request_id,
                  server_caller: build_server_caller(source: 'openai_responses', path: request.path, env: env)
                )

                log.info('[llm][api][namespaces][openai][responses] action=accepted ' \
                         "request_id=#{request_id} model=#{model} stream=#{streaming}")

                executor = Legion::LLM::Inference::Executor.new(inference_request)

                canonical_format = Legion::LLM::API::DebugFormats.canonical_format?(env)
                echo_request = Legion::LLM::API::DebugFormats.echo_request?(env)

                if streaming
                  content_type 'text/event-stream'
                  headers 'Cache-Control' => 'no-cache', 'Connection' => 'keep-alive', 'X-Accel-Buffering' => 'no'
                  stream do |out|
                    emitter = if canonical_format
                                Legion::LLM::API::DebugFormats.canonical_event_emitter(out)
                              else
                                translator.events_emitter(out, request_id: request_id, model: model)
                              end
                    Legion::LLM::API::DebugFormats.emit_echo_request_sse(out, canonical_request) if echo_request

                    assembler = Legion::LLM::API::StreamAssembler.new(
                      emitter:      emitter,
                      request_id:   request_id,
                      model:        model,
                      initial_lane: { id: 'unknown:pending' }
                    )
                    # N×N: Canonical streaming path — responses body is already
                    # translated to canonical form by the translator above.
                    pipeline_response = executor.call_stream { |c| assembler.push(c) }
                    assembler.finalize(pipeline_response)
                    log_api_completion_summary(
                      namespace:         'namespaces][openai][responses',
                      request_id:        request_id,
                      pipeline_response: pipeline_response,
                      stream:            true,
                      started_at:        request_started_at
                    )
                  rescue Legion::LLM::API::StreamAssembler::StreamClosed
                    # Client disconnected — caller treats as cancellation per G10.
                  rescue IOError, Errno::EPIPE
                    # Client disconnected mid-write before assembler caught it.
                  rescue StandardError => e
                    handle_exception(e, level: :error, handled: false,
                                        operation: 'llm.api.namespaces.openai.responses.stream', request_id: request_id)
                    out << "event: error\ndata: #{Legion::JSON.dump({ type: 'server_error', message: e.message })}\n\n"
                  end
                else
                  # N×N: Canonical path — responses body is already translated
                  # to canonical form; executor is format-agnostic.
                  pipeline_response = executor.call
                  log_api_completion_summary(
                    namespace:         'namespaces][openai][responses',
                    request_id:        request_id,
                    pipeline_response: pipeline_response,
                    stream:            false,
                    started_at:        request_started_at
                  )
                  set_routing_response_headers(pipeline_response: pipeline_response)

                  if canonical_format
                    status_code, response_headers, body_string = Legion::LLM::API::DebugFormats.render_canonical_response(
                      pipeline_response, canonical_request: canonical_request, env: env
                    )
                    status status_code
                    response_headers.each { |k, v| headers k => v }
                    body_string
                  else
                    formatted = translator.format_response(pipeline_response, request_id: request_id, model: model)
                    formatted = Legion::LLM::API::DebugFormats.attach_echo_request(formatted, canonical_request) if echo_request
                    content_type :json
                    status 200
                    Legion::JSON.dump(formatted)
                  end
                end
              rescue Legion::LLM::Errors::NoLaneAvailable => e
                translate_no_lane_available(e, operation: 'llm.api.namespaces.openai.responses.no_lane')
              rescue Legion::LLM::Errors::EscalationExhausted => e
                translate_escalation_exhausted(e, operation: 'llm.api.namespaces.openai.responses.exhausted')
              rescue Legion::LLM::Errors::InvalidHeader => e
                translate_invalid_header(e, operation: 'llm.api.namespaces.openai.responses.invalid_header')
              rescue Legion::LLM::Errors::RoutingRejected => e
                translate_routing_rejected(e, dialect: :openai, operation: 'llm.api.namespaces.openai.responses.routing_rejected')
              rescue Legion::LLM::AuthError => e
                handle_exception(e, level: :error, handled: true, operation: 'llm.api.namespaces.openai.responses.auth')
                openai_error(e.message, type: 'authentication_error', status_code: 401)
              rescue Legion::LLM::RateLimitError => e
                handle_exception(e, level: :warn, handled: true, operation: 'llm.api.namespaces.openai.responses.rate_limit')
                openai_error(e.message, type: 'rate_limit_error', code: 'rate_limit_exceeded', status_code: 429)
              rescue Legion::LLM::ProviderDown, Legion::LLM::ProviderError => e
                handle_exception(e, level: :error, handled: true, operation: 'llm.api.namespaces.openai.responses.provider')
                openai_error(e.message, type: 'server_error', status_code: 502)
              rescue StandardError => e
                handle_exception(e, level: :error, handled: false, operation: 'llm.api.namespaces.openai.responses')
                openai_error(e.message, type: 'server_error', status_code: 500)
              end

              app.get '/v1/responses/:id' do
                openai_error("Response '#{params[:id]}' not found", type: 'invalid_request_error',
                                                                    code: 'response_not_found', status_code: 404)
              end

              app.delete '/v1/responses/:id' do
                content_type :json
                Legion::JSON.dump({ id: params[:id], object: 'response', deleted: true })
              end

              app.post '/v1/responses/:id/cancel' do
                openai_error("Response '#{params[:id]}' not found or already completed",
                             type: 'invalid_request_error', status_code: 404)
              end

              app.get '/v1/responses/:id/input_items' do
                content_type :json
                Legion::JSON.dump({ object: 'list', data: [], has_more: false })
              end

              app.post '/v1/responses/:id/input_tokens/count' do
                body  = parse_request_body
                input = body[:input]
                model = body[:model] || params[:id]
                messages = case input
                           when Array  then Responses.normalize_input_array(input)
                           when String then [{ role: 'user', content: input }]
                           else []
                           end
                result = Legion::LLM::TokenEstimation.estimate(messages: messages, model: model.to_s)
                content_type :json
                Legion::JSON.dump(result)
              rescue StandardError => e
                handle_exception(e, level: :error, handled: false,
                                    operation: 'llm.api.namespaces.openai.responses.count_tokens')
                openai_error(e.message, type: 'server_error', status_code: 500)
              end

              app.post '/v1/responses/:id/compact' do
                openai_error("Response '#{params[:id]}' not found", type: 'invalid_request_error', status_code: 404)
              end

              app.post '/api/llm/inference/v1/responses' do
                call env.merge('PATH_INFO' => '/v1/responses')
              end

              log.debug('[llm][api][namespaces][openai][responses] routes registered')
            rescue StandardError => e
              handle_exception(e, level: :error, handled: false,
                                  operation: 'llm.api.namespaces.openai.responses.register')
            end

            # Helper kept at module-level for the input_tokens/count handler
            # (and as a public seam for tests). Mirrors the translator's
            # internal normalization but stays callable without instantiating
            # a translator.
            def self.normalize_input_array(input)
              messages = []
              pending = []

              input.each do |item|
                item = item.transform_keys(&:to_sym) if item.respond_to?(:transform_keys)
                case item[:type]&.to_s
                when 'function_call'
                  pending << {
                    id:        item[:call_id] || item[:id],
                    name:      item[:name].to_s,
                    arguments: item[:arguments].is_a?(String) ? item[:arguments] : Legion::JSON.dump(item[:arguments] || {})
                  }
                when 'function_call_output'
                  flush_pending(messages, pending)
                  messages << { role: 'tool', tool_call_id: item[:call_id], content: item[:output].to_s }
                else
                  role = item[:role]&.to_s

                  # SSOT: an assistant `message` arriving while calls are pending is
                  # the SAME turn as those calls (Codex order: function_call(s) →
                  # assistant message → function_call_output(s)). Merge its text onto
                  # the flushed assistant tool_calls message so the turn stays ONE
                  # message and the tool results that follow stay adjacent to their
                  # calls. Splitting it out wedges narration between a tool_call and
                  # its result — the malformed history behind the dead stop.
                  if role == 'assistant' && !pending.empty?
                    content = item[:content]
                    content = content.to_s if content && !content.is_a?(Array)
                    flush_pending(messages, pending, assistant_content: content)
                    next
                  end

                  flush_pending(messages, pending)
                  next unless role

                  role = 'system' if role == 'developer'

                  content = item[:content]
                  content = content.to_s if content && !content.is_a?(Array)
                  messages << { role: role, content: content }.compact
                end
              end
              flush_pending(messages, pending)
              messages
            end

            def self.flush_pending(messages, pending, assistant_content: nil)
              if pending.empty?
                messages << { role: 'assistant', content: assistant_content } if assistant_content
                return
              end

              messages << {
                role:       'assistant',
                content:    assistant_content.to_s,
                tool_calls: pending.map do |tc|
                  { id: tc[:id], type: 'function', function: { name: tc[:name], arguments: tc[:arguments] } }
                end
              }
              pending.clear
            end
          end
        end
      end
    end
  end
end
