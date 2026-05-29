# frozen_string_literal: true

require 'securerandom'
require 'sinatra/base'
require 'sinatra/extension'
require 'sinatra/namespace'
require 'legion/logging/helper'
require 'legion/llm/types'
require 'legion/llm/api/translators/anthropic_request'
require 'legion/llm/api/translators/anthropic_response'

module Legion
  module LLM
    module API
      module Namespaces
        module Anthropic
          module Messages
            extend Sinatra::Extension

            # rubocop:disable Metrics/BlockLength
            post '' do
              require_llm!
              body = parse_request_body

              validate_anthropic_required!(body)

              request_id = "msg_#{SecureRandom.hex(12)}"
              normalized = Legion::LLM::API::Translators::AnthropicRequest.normalize(body)
              streaming = normalized[:stream] == true

              require 'legion/llm/inference/request' unless defined?(Legion::LLM::Inference::Request)
              require 'legion/llm/inference/executor' unless defined?(Legion::LLM::Inference::Executor)

              tool_defs = build_tool_definitions(normalized[:tools] || [], executable: false)
              modality = detect_modality(normalized[:messages])

              pipeline_request = Legion::LLM::Inference::Request.build(
                id:       request_id,
                messages: normalized[:messages],
                system:   normalized[:system],
                routing:  {},
                tools:    tool_defs,
                caller:   build_server_caller(source: 'anthropic_compat', path: request.path, env: env),
                stream:   streaming,
                modality: modality,
                cache:    { strategy: :default, cacheable: true }
              )

              executor = Legion::LLM::Inference::Executor.new(pipeline_request)
              model = body[:model]

              if streaming
                content_type 'text/event-stream'
                headers 'Cache-Control' => 'no-cache', 'Connection' => 'keep-alive', 'X-Accel-Buffering' => 'no'

                stream do |out|
                  full_text = +''
                  text_block_opened = false

                  out << "event: message_start\ndata: #{Legion::JSON.dump({
                                                                            type:    'message_start',
                                                                            message: {
                                                                              id: request_id, type: 'message', role: 'assistant',
                      content: [], model: model.to_s,
                      stop_reason: nil, stop_sequence: nil,
                      usage: { input_tokens: 0, output_tokens: 0 }
                                                                            }
                                                                          })}\n\n"

                  pipeline_response = executor.call_stream do |chunk|
                    text = chunk.respond_to?(:content) ? chunk.content.to_s : chunk.to_s
                    next if text.empty?

                    unless text_block_opened
                      out << "event: content_block_start\ndata: #{Legion::JSON.dump({
                                                                                      type: 'content_block_start', index: 0,
                        content_block: { type: 'text', text: '' }
                                                                                    })}\n\n"
                      out << "event: ping\ndata: #{Legion::JSON.dump({ type: 'ping' })}\n\n"
                      text_block_opened = true
                    end

                    full_text << text
                    delta_event = Legion::LLM::API::Translators::AnthropicResponse.format_chunk(text)
                    out << "event: content_block_delta\ndata: #{Legion::JSON.dump(delta_event)}\n\n"
                  end

                  translator = Legion::LLM::API::Translators::AnthropicResponse
                  tool_calls = translator.extract_tool_calls(pipeline_response)
                  tokens = pipeline_response.respond_to?(:tokens) ? pipeline_response.tokens : nil
                  stop_reason = tool_calls.any? ? 'tool_use' : translator.format_stop_reason(pipeline_response)
                  content_index = 0

                  if text_block_opened
                    out << "event: content_block_stop\ndata: #{Legion::JSON.dump({ type: 'content_block_stop', index: 0 })}\n\n"
                    content_index = 1
                  end

                  tool_calls.each do |tc|
                    out << "event: content_block_start\ndata: #{Legion::JSON.dump({
                                                                                    type: 'content_block_start', index: content_index,
                      content_block: { type: 'tool_use', id: tc[:id] || "toolu_#{SecureRandom.hex(12)}", name: tc[:name], input: {} }
                                                                                  })}\n\n"
                    out << "event: content_block_delta\ndata: #{Legion::JSON.dump({
                                                                                    type: 'content_block_delta', index: content_index,
                      delta: { type: 'input_json_delta', partial_json: Legion::JSON.dump(tc[:arguments] || {}) }
                                                                                  })}\n\n"
                    out << "event: content_block_stop\ndata: #{Legion::JSON.dump({ type: 'content_block_stop', index: content_index })}\n\n"
                    content_index += 1
                  end

                  out << "event: message_delta\ndata: #{Legion::JSON.dump({
                                                                            type: 'message_delta',
                    delta: { stop_reason: stop_reason, stop_sequence: nil },
                    usage: { output_tokens: translator.token_count(tokens, :output) }
                                                                          })}\n\n"
                  out << "event: message_stop\ndata: #{Legion::JSON.dump({ type: 'message_stop' })}\n\n"
                rescue StandardError => e
                  handle_exception(e, level: :error, handled: false, operation: 'llm.ns.anthropic.messages.stream', request_id: request_id)
                  out << "event: error\ndata: #{Legion::JSON.dump({ type: 'error', error: { type: 'api_error', message: e.message } })}\n\n"
                end
              else
                pipeline_response = executor.call
                formatted = Legion::LLM::API::Translators::AnthropicResponse.format(
                  pipeline_response, model: model, request_id: request_id
                )

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
            # rubocop:enable Metrics/BlockLength

            helpers do
              def validate_anthropic_required!(body)
                missing = []
                missing << 'model' if body[:model].nil? || body[:model].to_s.empty?
                missing << 'messages' if body[:messages].nil? || !body[:messages].is_a?(Array) || body[:messages].empty?
                missing << 'max_tokens' if body[:max_tokens].nil?
                return if missing.empty?

                halt 400, { 'Content-Type' => 'application/json' },
                     Legion::JSON.dump({ type: 'error', error: { type: 'invalid_request_error', message: "missing required fields: #{missing.join(', ')}" } })
              end
            end
          end
        end
      end
    end
  end
end
