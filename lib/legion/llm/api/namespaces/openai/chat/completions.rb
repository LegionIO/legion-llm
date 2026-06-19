# frozen_string_literal: true

require 'legion/logging/helper'
require 'legion/llm/api/namespaces/helpers'
require 'legion/llm/api/client_translators/openai_chat'
require 'legion/llm/api/stream_assembler'
require 'legion/llm/api/debug_formats'

module Legion
  module LLM
    module API
      module Namespaces
        module OpenAI
          module Chat
            # Sinatra extension for /v1/chat/completions —
            # parse → translate → execute → respond.
            module Completions
              extend Legion::Logging::Helper

              def self.registered(app) # rubocop:disable Metrics/AbcSize
                log.debug('[llm][api][namespaces][openai][chat] registering routes')

                app.post '/v1/chat/completions' do
                  require_llm!
                  validate_legion_routing_headers!(env)
                  request_started_at = ::Process.clock_gettime(::Process::CLOCK_MONOTONIC)
                  body = parse_request_body

                  unless body[:messages].is_a?(Array) && !body[:messages].empty?
                    return openai_error('messages is required and must be a non-empty array',
                                        type: 'invalid_request_error', code: nil, status_code: 400)
                  end

                  translator = Legion::LLM::API::ClientTranslators::OpenAIChat.new
                  canonical_request = translator.parse_request(body, env)
                  request_id = canonical_request.id
                  model = body[:model] || Legion::Settings[:llm][:default_model] || 'default'
                  streaming = canonical_request.stream
                  include_reasoning = canonical_request.metadata[:include_reasoning] != false

                  Completions.gaia_ingest(body[:messages], request_id, identity_canonical_name(env))

                  inference_request = translator.build_inference_request(
                    canonical_request,
                    request_id:    request_id,
                    server_caller: build_server_caller(
                      source: 'openai_compat', path: request.path, env: env,
                      caller_context: canonical_request.metadata[:caller_context]
                    )
                  )

                  log.info('[llm][api][namespaces][openai][chat] action=accepted ' \
                           "request_id=#{request_id} model=#{model} stream=#{streaming} " \
                           "messages=#{canonical_request.messages.size} tools=#{canonical_request.tools.size}")

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
                                  translator.events_emitter(
                                    out, request_id: request_id, model: model,
                                         include_reasoning: include_reasoning
                                  )
                                end
                      Legion::LLM::API::DebugFormats.emit_echo_request_sse(out, canonical_request) if echo_request

                      assembler = Legion::LLM::API::StreamAssembler.new(
                        emitter:      emitter,
                        request_id:   request_id,
                        model:        model,
                        initial_lane: { id: 'unknown:pending' }
                      )
                      pipeline_response = executor.call_stream { |c| assembler.push(c) }
                      assembler.finalize(pipeline_response)
                      log_api_completion_summary(
                        namespace:         'namespaces][openai][chat',
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
                                          operation: 'llm.api.namespaces.openai.chat.stream', request_id: request_id)
                      out << "data: #{Legion::JSON.dump({ error: { message: e.message, type: 'server_error' } })}\n\n"
                      out << "data: [DONE]\n\n"
                    end
                  else
                    pipeline_response = executor.call
                    log_api_completion_summary(
                      namespace:         'namespaces][openai][chat',
                      request_id:        request_id,
                      pipeline_response: pipeline_response,
                      stream:            false,
                      started_at:        request_started_at
                    )

                    if canonical_format
                      status_code, response_headers, body_string = Legion::LLM::API::DebugFormats.render_canonical_response(
                        pipeline_response, canonical_request: canonical_request, env: env
                      )
                      status status_code
                      response_headers.each { |k, v| headers k => v }
                      body_string
                    else
                      response_body = translator.format_response(
                        pipeline_response, model: model, request_id: request_id, include_reasoning: include_reasoning
                      )
                      response_body = Legion::LLM::API::DebugFormats.attach_echo_request(response_body, canonical_request) if echo_request
                      content_type :json
                      status 200
                      Legion::JSON.dump(response_body)
                    end
                  end
                rescue Legion::LLM::Errors::NoLaneAvailable => e
                  translate_no_lane_available(e, operation: 'llm.api.namespaces.openai.chat.no_lane')
                rescue Legion::LLM::Errors::EscalationExhausted => e
                  translate_escalation_exhausted(e, operation: 'llm.api.namespaces.openai.chat.exhausted')
                rescue Legion::LLM::Errors::InvalidHeader => e
                  translate_invalid_header(e, operation: 'llm.api.namespaces.openai.chat.invalid_header')
                rescue Legion::LLM::AuthError => e
                  handle_exception(e, level: :error, handled: true, operation: 'llm.api.namespaces.openai.chat.auth')
                  openai_error(e.message, type: 'authentication_error', status_code: 401)
                rescue Legion::LLM::RateLimitError => e
                  handle_exception(e, level: :warn, handled: true, operation: 'llm.api.namespaces.openai.chat.rate_limit')
                  openai_error(e.message, type: 'rate_limit_error', code: 'rate_limit_exceeded', status_code: 429)
                rescue Legion::LLM::ProviderDown, Legion::LLM::ProviderError => e
                  handle_exception(e, level: :error, handled: true, operation: 'llm.api.namespaces.openai.chat.provider')
                  openai_error(e.message, type: 'server_error', status_code: 502)
                rescue StandardError => e
                  handle_exception(e, level: :error, handled: false, operation: 'llm.api.namespaces.openai.chat')
                  openai_error(e.message, type: 'server_error', status_code: 500)
                end

                app.get '/v1/chat/completions' do
                  content_type :json
                  Legion::JSON.dump({ object: 'list', data: [], has_more: false })
                end

                app.get '/v1/chat/completions/:id' do
                  openai_error("Chat completion '#{params[:id]}' not found",
                               type: 'invalid_request_error', code: 'completion_not_found', status_code: 404)
                end

                app.post '/v1/chat/completions/:id' do
                  openai_error("Chat completion '#{params[:id]}' not found",
                               type: 'invalid_request_error', code: 'completion_not_found', status_code: 404)
                end

                app.delete '/v1/chat/completions/:id' do
                  content_type :json
                  Legion::JSON.dump({ id: params[:id], object: 'chat.completion', deleted: true })
                end

                log.debug('[llm][api][namespaces][openai][chat] routes registered')
              rescue StandardError => e
                handle_exception(e, level: :error, handled: false, operation: 'llm.api.namespaces.openai.chat.register')
              end

              # Optional GAIA ingestion for the last user message — preserved
              # from the legacy route. The translator handles parsing; this is
              # a sidecar enrichment that continues to live on the route since
              # it depends on the GAIA singleton + identity helpers.
              def self.gaia_ingest(messages, request_id, caller_identity)
                return unless defined?(Legion::Gaia) && Legion::Gaia.respond_to?(:started?) && Legion::Gaia.started?

                last_user = Array(messages).select { |m| (m[:role] || m['role']).to_s == 'user' }.last
                prompt = (last_user || {})[:content] || (last_user || {})['content'] || ''
                return if prompt.to_s.empty?

                frame = Legion::Gaia::InputFrame.new(
                  content:      prompt.to_s,
                  channel_id:   :api,
                  content_type: :text,
                  auth_context: { identity: caller_identity },
                  metadata:     { source_type: :human_direct, salience: 0.9 }
                )
                Legion::Gaia.ingest(frame)
                log.debug("[llm][api][namespaces][openai][chat] action=gaia_ingest request_id=#{request_id}")
              rescue StandardError => e
                log.warn("[llm][api][namespaces][openai][chat] gaia_ingest failed: #{e.message}")
              end
            end
          end
        end
      end
    end
  end
end
