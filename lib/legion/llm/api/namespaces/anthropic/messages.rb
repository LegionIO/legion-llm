# frozen_string_literal: true

require 'sinatra/base'
require 'sinatra/extension'
require 'sinatra/namespace'
require 'legion/logging/helper'
require 'legion/llm/api/client_translators/anthropic_messages'
require 'legion/llm/api/stream_assembler'

module Legion
  module LLM
    module API
      module Namespaces
        module Anthropic
          # Sinatra extension for /v1/messages — parse → translate → execute → respond.
          # All translation lives in API::ClientTranslators::AnthropicMessages.
          module Messages
            extend Sinatra::Extension

            post '' do
              require_llm!
              request_started_at = ::Process.clock_gettime(::Process::CLOCK_MONOTONIC)
              body = parse_request_body
              validate_anthropic_required!(body)

              translator = Legion::LLM::API::ClientTranslators::AnthropicMessages.new
              canonical_request = translator.parse_request(body, env)
              request_id = canonical_request.id
              model = body[:model]
              streaming = canonical_request.stream

              inference_request = translator.build_inference_request(
                canonical_request,
                request_id:    request_id,
                server_caller: build_server_caller(source: 'anthropic_compat', path: request.path, env: env),
                modality:      detect_modality(canonical_request.messages.map { |m| m.respond_to?(:to_h) ? m.to_h : m })
              )

              log.info("[llm][api][anthropic] action=request request_id=#{request_id} " \
                       "messages=#{inference_request.messages.size} tools=#{inference_request.tools.size} stream=#{streaming}")

              executor = Legion::LLM::Inference::Executor.new(inference_request)
              conv_id = inference_request.conversation_id

              if streaming
                content_type 'text/event-stream'
                headers 'Cache-Control' => 'no-cache', 'Connection' => 'keep-alive',
                        'X-Accel-Buffering' => 'no', 'X-Legion-Conversation-Id' => conv_id

                stream do |out|
                  emitter = translator.events_emitter(out, request_id: request_id, model: model, conv_id: conv_id)
                  assembler = Legion::LLM::API::StreamAssembler.new(
                    emitter:      emitter,
                    request_id:   request_id,
                    model:        model,
                    input_tokens: estimate_input_tokens(inference_request.messages)
                  )
                  pipeline_response = executor.call_stream do |chunk|
                    assembler.push(chunk)
                  end
                  assembler.finalize(pipeline_response)
                  log_api_completion_summary(
                    namespace:         'anthropic',
                    request_id:        request_id,
                    pipeline_response: pipeline_response,
                    stream:            true,
                    started_at:        request_started_at
                  )
                rescue Legion::LLM::API::StreamAssembler::StreamClosed
                  # Client disconnected — assembler logged the disconnect; treat as cancellation (G10).
                rescue IOError, Errno::EPIPE
                  # Client disconnected mid-write before assembler caught it.
                rescue StandardError => e
                  handle_exception(e, level: :error, handled: false,
                                      operation: 'llm.ns.anthropic.messages.stream', request_id: request_id)
                end
              else
                pipeline_response = executor.call
                formatted = translator.format_response(pipeline_response, model: model, request_id: request_id)
                log_api_completion_summary(
                  namespace:         'anthropic',
                  request_id:        request_id,
                  pipeline_response: pipeline_response,
                  stream:            false,
                  started_at:        request_started_at
                )

                headers 'X-Legion-Conversation-Id' => conv_id
                content_type :json
                status 200
                Legion::JSON.dump(formatted)
              end
            rescue Legion::LLM::AuthError => e
              handle_exception(e, level: :error, handled: true, operation: 'llm.ns.anthropic.messages.auth')
              anthropic_error('authentication_error', e.message, status_code: 401)
            rescue Legion::LLM::RateLimitError => e
              handle_exception(e, level: :error, handled: true, operation: 'llm.ns.anthropic.messages.rate_limit')
              anthropic_error('rate_limit_error', e.message, status_code: 429)
            rescue Legion::LLM::ContextOverflow => e
              handle_exception(e, level: :error, handled: true, operation: 'llm.ns.anthropic.messages.context')
              anthropic_error('invalid_request_error', e.message, status_code: 400)
            rescue Legion::LLM::ProviderDown, Legion::LLM::ProviderError => e
              handle_exception(e, level: :error, handled: true, operation: 'llm.ns.anthropic.messages.provider')
              anthropic_error('overloaded_error', e.message, status_code: 529)
            rescue StandardError => e
              handle_exception(e, level: :error, handled: false, operation: 'llm.ns.anthropic.messages')
              anthropic_error('api_error', e.message, status_code: 500)
            end

            helpers do
              def validate_anthropic_required!(body)
                missing = []
                missing << 'messages' if body[:messages].nil? || !body[:messages].is_a?(Array) || body[:messages].empty?
                missing << 'max_tokens' if body[:max_tokens].nil?
                return if missing.empty?

                halt 400, { 'Content-Type' => 'application/json' },
                     Legion::JSON.dump({ type:  'error',
                                         error: { type: 'invalid_request_error', message: "missing required fields: #{missing.join(', ')}" } })
              end

              def estimate_input_tokens(messages)
                chars = messages.sum { |m| (m[:content].is_a?(String) ? m[:content] : m[:content].to_s).length }
                (chars / 4.0).ceil
              end
            end
          end
        end
      end
    end
  end
end
