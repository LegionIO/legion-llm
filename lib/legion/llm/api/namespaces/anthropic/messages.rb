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

              conv_id = env['HTTP_X_LEGION_CONVERSATION_ID'] || body[:conversation_id] || "conv_#{SecureRandom.hex(8)}"
              ext_provider = env['HTTP_X_LEGION_PROVIDER'] || body[:provider]
              ext_tier = env['HTTP_X_LEGION_TIER'] || body[:tier]
              ext_instance = env['HTTP_X_LEGION_INSTANCE'] || body[:instance]

              routing = { provider: ext_provider, instance: ext_instance }.compact
              extra = {}
              extra[:tier] = ext_tier.to_sym if ext_tier

              pipeline_request = Legion::LLM::Inference::Request.build(
                id:              request_id,
                messages:        normalized[:messages],
                system:          normalized[:system],
                routing:         routing,
                tools:           tool_defs,
                caller:          build_server_caller(source: 'anthropic_compat', path: request.path, env: env),
                conversation_id: conv_id,
                stream:          streaming,
                modality:        modality,
                cache:           { strategy: :default, cacheable: true },
                extra:           extra.empty? ? {} : extra
              )

              msg_count = normalized[:messages].size
              msg_chars = normalized[:messages].sum { |m| (m[:content].is_a?(String) ? m[:content] : m[:content].to_s).length }
              est_tokens = (msg_chars / 4.0).ceil
              log.info "[llm][api][anthropic] action=request request_id=#{request_id} " \
                       "messages=#{msg_count} chars=#{msg_chars} est_tokens=#{est_tokens} " \
                       "tools=#{tool_defs.size} stream=#{streaming}"
              normalized[:messages].each_with_index do |m, i|
                role = m[:role]
                content = m[:content].is_a?(String) ? m[:content] : m[:content].to_s
                tc = m[:tool_calls]
                tcid = m[:tool_call_id]
                log.debug "[llm][api][anthropic] action=request_msg idx=#{i} role=#{role} " \
                          "content_length=#{content.length} content_preview=#{content[0, 120]} " \
                          "tool_calls=#{tc&.size || 0} tool_call_id=#{tcid}"
              end

              executor = Legion::LLM::Inference::Executor.new(pipeline_request)
              model = body[:model]

              if streaming
                content_type 'text/event-stream'
                headers 'Cache-Control' => 'no-cache', 'Connection' => 'keep-alive',
                        'X-Accel-Buffering' => 'no', 'X-Legion-Conversation-Id' => conv_id

                stream do |out|
                  full_text = +''
                  text_block_opened = false

                  out << "event: message_start\ndata: #{Legion::JSON.dump({
                                                                            type:    'message_start',
                                                                            message: {
                                                                              id: request_id, type: 'message', role: 'assistant',
                      content: [], model: model.to_s,
                      stop_reason: nil, stop_sequence: nil,
                      usage: { input_tokens: est_tokens, output_tokens: 0 }
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

                  if !text_block_opened && tool_calls.empty?
                    fallback_text = extract_fallback_text(pipeline_response)
                    unless fallback_text.empty?
                      out << "event: content_block_start\ndata: #{Legion::JSON.dump({
                                                                                      type: 'content_block_start', index: 0,
                        content_block: { type: 'text', text: '' }
                                                                                    })}\n\n"
                      out << "event: content_block_delta\ndata: #{Legion::JSON.dump({
                                                                                      type: 'content_block_delta', index: 0,
                        delta: { type: 'text_delta', text: fallback_text }
                                                                                    })}\n\n"
                      text_block_opened = true
                    end
                  end

                  log.info "[llm][api][anthropic] action=stream_post request_id=#{request_id} " \
                           "tool_calls=#{tool_calls.size} stop_reason=#{stop_reason} " \
                           "text_block_opened=#{text_block_opened} full_text_length=#{full_text.length}"

                  if tool_calls.empty? && full_text.empty?
                    log.warn "[llm][api][anthropic] action=empty_response request_id=#{request_id} " \
                             "model=#{model} text_block_opened=#{text_block_opened} — provider returned no content, signaling overloaded"
                    out << "event: error\ndata: #{Legion::JSON.dump({
                      type: 'error', error: { type: 'overloaded_error',
                      message: 'Model returned empty response. Please retry.' }
                    })}\n\n"
                    next
                  end

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
                                                                            type:  'message_delta',
                                                                            delta: { stop_reason: stop_reason, stop_sequence: nil },
                                                                            usage: { input_tokens: translator.token_count(tokens, :input),
                                                                                     output_tokens: translator.token_count(tokens, :output) }
                                                                          })}\n\n"
                  out << "event: message_stop\ndata: #{Legion::JSON.dump({ type: 'message_stop' })}\n\n"
                  log.info "[llm][api][anthropic] action=stream_complete request_id=#{request_id} stop_reason=#{stop_reason}"
                rescue StandardError => e
                  handle_exception(e, level: :error, handled: false, operation: 'llm.ns.anthropic.messages.stream', request_id: request_id)
                  out << "event: error\ndata: #{Legion::JSON.dump({ type: 'error', error: { type: 'api_error', message: e.message } })}\n\n"
                end
              else
                pipeline_response = executor.call
                formatted = Legion::LLM::API::Translators::AnthropicResponse.format(
                  pipeline_response, model: model, request_id: request_id
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

              def extract_fallback_text(pipeline_response)
                msg = pipeline_response.message
                text = msg.is_a?(Hash) ? (msg[:content] || msg['content']).to_s : ''
                return text unless text.empty?
                return '' unless pipeline_response.respond_to?(:thinking) && pipeline_response.thinking

                thinking_data = pipeline_response.thinking
                thinking_content = if thinking_data.is_a?(Hash)
                                     thinking_data[:content] || thinking_data['content']
                                   elsif thinking_data.respond_to?(:content)
                                     thinking_data.content
                                   end
                thinking_content.to_s.strip
              end
            end
          end
        end
      end
    end
  end
end
