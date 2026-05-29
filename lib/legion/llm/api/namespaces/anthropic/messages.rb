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

              tool_defs = build_tool_definitions(normalized[:tools] || [], executable: true)

              pipeline_request = Legion::LLM::Inference::Request.build(
                id:       request_id,
                messages: normalized[:messages],
                system:   normalized[:system],
                routing:  normalized[:routing],
                tools:    tool_defs,
                caller:   build_server_caller(source: 'anthropic_compat', path: request.path, env: env),
                stream:   streaming,
                cache:    { strategy: :default, cacheable: true }
              )

              executor = Legion::LLM::Inference::Executor.new(pipeline_request)
              model = body[:model]

              if streaming
                content_type 'text/event-stream'
                headers 'Cache-Control' => 'no-cache', 'Connection' => 'keep-alive', 'X-Accel-Buffering' => 'no'

                stream do |out|
                  full_text = +''

                  # Emit opening events BEFORE any content_block_delta events.
                  # message_start must be the very first event the client receives.
                  out << "event: message_start\ndata: #{Legion::JSON.dump({
                                                                            type:    'message_start',
                                                                            message: {
                                                                              id: request_id, type: 'message', role: 'assistant',
                      content: [], model: model.to_s,
                      stop_reason: nil, stop_sequence: nil,
                      usage: { input_tokens: 0, output_tokens: 0 }
                                                                            }
                                                                          })}\n\n"
                  out << "event: content_block_start\ndata: #{Legion::JSON.dump({
                                                                                  type: 'content_block_start', index: 0,
                    content_block: { type: 'text', text: '' }
                                                                                })}\n\n"
                  out << "event: ping\ndata: #{Legion::JSON.dump({ type: 'ping' })}\n\n"

                  # Stream content_block_delta events live as chunks arrive.
                  pipeline_response = executor.call_stream do |chunk|
                    text = chunk.respond_to?(:content) ? chunk.content.to_s : chunk.to_s
                    next if text.empty?

                    full_text << text
                    delta_event = Legion::LLM::API::Translators::AnthropicResponse.format_chunk(text)
                    out << "event: content_block_delta\ndata: #{Legion::JSON.dump(delta_event)}\n\n"
                  end

                  # Emit closing events AFTER all deltas. Filter streaming_events to
                  # the tail events. Skip message_start, ping, and text content_block_delta
                  # since those were already emitted above. For content_block_start, skip
                  # only the first text block (index 0) — tool_use blocks at higher indices
                  # must be emitted here. Allow input_json_delta content_block_delta events
                  # for tool arguments.
                  skip_prefix = Set['message_start', 'ping']
                  events = Legion::LLM::API::Translators::AnthropicResponse.streaming_events(
                    pipeline_response, model: model, request_id: request_id, full_text: full_text
                  )
                  events.each do |event_name, payload|
                    if event_name == 'content_block_start'
                      next if payload[:index].to_i.zero?
                    elsif event_name == 'content_block_delta'
                      next unless payload.dig(:delta, :type) == 'input_json_delta'
                    elsif skip_prefix.include?(event_name)
                      next
                    end

                    out << "event: #{event_name}\ndata: #{Legion::JSON.dump(payload)}\n\n"
                  end
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
