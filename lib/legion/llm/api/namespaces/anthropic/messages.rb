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
              request_started_at = ::Process.clock_gettime(::Process::CLOCK_MONOTONIC)
              body = parse_request_body

              validate_anthropic_required!(body)

              request_id = env['HTTP_X_CLIENT_REQUEST_ID'] || "msg_#{SecureRandom.hex(12)}"
              normalized = Legion::LLM::API::Translators::AnthropicRequest.normalize(body)
              streaming = normalized[:stream] == true

              require 'legion/llm/inference/request' unless defined?(Legion::LLM::Inference::Request)
              require 'legion/llm/inference/executor' unless defined?(Legion::LLM::Inference::Executor)

              tool_defs = build_tool_definitions(normalized[:tools] || [], executable: false)
              modality = detect_modality(normalized[:messages])

              conv_id = env['HTTP_X_LEGION_CONVERSATION_ID'] || body[:conversation_id] || env['HTTP_THREAD_ID'] || env['HTTP_X_CLAUDE_CODE_SESSION_ID'] || "conv_#{SecureRandom.hex(8)}"
              ext_provider = env['HTTP_X_LEGION_PROVIDER'] || body[:provider]
              ext_tier = env['HTTP_X_LEGION_TIER'] || body[:tier]
              ext_instance = env['HTTP_X_LEGION_INSTANCE'] || body[:instance]
              model = body[:model]

              routing = { provider: ext_provider, instance: ext_instance, model: model }.compact
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
                thinking:        body[:thinking],
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

              if streaming
                content_type 'text/event-stream'
                headers 'Cache-Control' => 'no-cache', 'Connection' => 'keep-alive',
                        'X-Accel-Buffering' => 'no', 'X-Legion-Conversation-Id' => conv_id

                stream do |out|
                  full_text = +''
                  full_thinking = +''
                  full_thinking_signature = nil
                  text_block_opened = false
                  text_block_index = nil
                  thinking_block_opened = false
                  thinking_block_closed = false
                  thinking_block_index = nil
                  next_block_index = 0
                  stream_closed = false
                  emit_thinking_blocks = false

                  write_stream = lambda do |data|
                    return false if stream_closed

                    out << data
                    true
                  rescue IOError, Errno::EPIPE => e
                    stream_closed = true
                    log.warn "[llm][api][anthropic] action=client_stream_error request_id=#{request_id} error=#{e.class}: #{e.message}"
                    raise
                  end

                  emit_event = lambda do |event_name, payload|
                    write_stream.call("event: #{event_name}\ndata: #{Legion::JSON.dump(payload)}\n\n")
                  end

                  emit_event.call('message_start', {
                                    type:    'message_start',
                                    message: {
                                      id:            request_id,
                                      type:          'message',
                                      role:          'assistant',
                                      content:       [],
                                      model:         model.to_s,
                                      stop_reason:   nil,
                                      stop_sequence: nil,
                                      usage:         { input_tokens: est_tokens, output_tokens: 0 }
                                    }
                                  })
                  next if stream_closed

                  pipeline_response = executor.call_stream do |chunk|
                    text = extract_chunk_text(chunk)
                    thinking_payload = extract_chunk_thinking_payload(chunk)
                    thinking = thinking_payload[:content].to_s if thinking_payload
                    thinking_signature = thinking_payload[:signature].to_s if thinking_payload

                    if thinking_payload && (!thinking.to_s.empty? || !thinking_signature.to_s.empty?)
                      full_thinking << thinking unless thinking.to_s.empty?
                      full_thinking_signature ||= thinking_signature unless thinking_signature.to_s.empty?
                    end

                    if emit_thinking_blocks && thinking_payload && (!thinking.to_s.empty? || !thinking_signature.to_s.empty?)
                      unless thinking_block_opened || thinking_block_closed
                        thinking_block_index = next_block_index
                        emit_event.call('content_block_start', {
                                          type:          'content_block_start',
                                          index:         thinking_block_index,
                                          content_block: { type: 'thinking', thinking: '', signature: '' }
                                        })
                        next if stream_closed

                        thinking_block_opened = true
                        next_block_index += 1
                      end

                      unless thinking.to_s.empty?
                        emit_event.call('content_block_delta', {
                                          type:  'content_block_delta',
                                          index: thinking_block_index,
                                          delta: { type: 'thinking_delta', thinking: thinking }
                                        })
                        next if stream_closed
                      end
                    end

                    next if text.empty?

                    if thinking_block_opened && !thinking_block_closed
                      emit_thinking_signature_delta(emit_event, thinking_block_index, full_thinking_signature)
                      next if stream_closed

                      emit_event.call('content_block_stop', { type: 'content_block_stop', index: thinking_block_index })
                      next if stream_closed

                      thinking_block_closed = true
                    end

                    unless text_block_opened
                      text_block_index = next_block_index
                      emit_event.call('content_block_start', {
                                        type:          'content_block_start',
                                        index:         text_block_index,
                                        content_block: { type: 'text', text: '' }
                                      })
                      next if stream_closed

                      emit_event.call('ping', { type: 'ping' })
                      next if stream_closed

                      text_block_opened = true
                      next_block_index += 1
                    end

                    unless text.empty?
                      full_text << text
                      delta_event = Legion::LLM::API::Translators::AnthropicResponse.format_chunk(text, index: text_block_index)
                      emit_event.call('content_block_delta', delta_event)
                      next if stream_closed
                    end
                  end

                  translator = Legion::LLM::API::Translators::AnthropicResponse
                  tool_calls = translator.extract_tool_calls(pipeline_response)
                  tokens = pipeline_response.respond_to?(:tokens) ? pipeline_response.tokens : nil
                  stop_reason = translator.format_stop_reason(pipeline_response)
                  final_thinking = translator.thinking_payload(pipeline_response)
                  full_thinking_signature ||= final_thinking[:signature] if final_thinking && final_thinking[:signature]
                  content_index = next_block_index

                  if final_thinking && !thinking_block_opened
                    final_thinking_text = final_thinking[:content].to_s
                    full_thinking << final_thinking_text unless final_thinking_text.empty? || full_thinking.include?(final_thinking_text)
                  end

                  if emit_thinking_blocks && final_thinking && !thinking_block_opened
                    thinking_block_index = next_block_index
                    thinking_text = final_thinking[:content].to_s
                    emit_event.call('content_block_start', {
                                      type:          'content_block_start',
                                      index:         thinking_block_index,
                                      content_block: { type: 'thinking', thinking: '', signature: '' }
                                    })
                    next if stream_closed

                    unless thinking_text.empty?
                      full_thinking << thinking_text
                      emit_event.call('content_block_delta', {
                                        type:  'content_block_delta',
                                        index: thinking_block_index,
                                        delta: { type: 'thinking_delta', thinking: thinking_text }
                                      })
                      next if stream_closed
                    end

                    thinking_block_opened = true
                    next_block_index += 1
                    content_index = next_block_index
                  end

                  if thinking_block_opened && !thinking_block_closed
                    emit_thinking_signature_delta(emit_event, thinking_block_index, full_thinking_signature)
                    next if stream_closed

                    emit_event.call('content_block_stop', { type: 'content_block_stop', index: thinking_block_index })
                    next if stream_closed

                    thinking_block_closed = true
                    content_index = next_block_index
                  end

                  if !text_block_opened && tool_calls.empty?
                    fallback_text = extract_fallback_text(pipeline_response)
                    unless fallback_text.empty?
                      text_block_index = next_block_index
                      emit_event.call('content_block_start', {
                                        type:          'content_block_start',
                                        index:         text_block_index,
                                        content_block: { type: 'text', text: '' }
                                      })
                      next if stream_closed

                      emit_event.call('content_block_delta', {
                                        type:  'content_block_delta',
                                        index: text_block_index,
                                        delta: { type: 'text_delta', text: fallback_text }
                                      })
                      next if stream_closed

                      text_block_opened = true
                      full_text << fallback_text
                      next_block_index += 1
                      content_index = next_block_index
                    end
                  end

                  log.info "[llm][api][anthropic] action=stream_post request_id=#{request_id} " \
                           "tool_calls=#{tool_calls.size} stop_reason=#{stop_reason} " \
                           "text_block_opened=#{text_block_opened} full_text_length=#{full_text.length} " \
                           "internal_thinking_length=#{full_thinking.length}"

                  if tool_calls.empty? && full_text.empty? && full_thinking.empty?
                    log.warn "[llm][api][anthropic] action=empty_response request_id=#{request_id} " \
                             "model=#{model} text_block_opened=#{text_block_opened} internal_thinking_length=#{full_thinking.length} " \
                             '— provider returned no client-visible content'
                    emit_event.call('error', {
                                      type:  'error',
                                      error: {
                                        type:    'overloaded_error',
                                        message: 'Model returned empty response. Please retry.'
                                      }
                                    })
                    next
                  end

                  if text_block_opened
                    emit_event.call('content_block_stop', { type: 'content_block_stop', index: text_block_index })
                    next if stream_closed

                    content_index = next_block_index
                  end

                  tool_calls.each do |tc|
                    is_server_tool = tc[:legionio] == true

                    emit_event.call('content_block_start', {
                                      type:          'content_block_start',
                                      index:         content_index,
                                      content_block: {
                                        type:  is_server_tool ? 'server_tool_use' : 'tool_use',
                                        id:    tc[:id] || (is_server_tool ? "srvtoolu_#{SecureRandom.hex(12)}" : "toolu_#{SecureRandom.hex(12)}"),
                                        name:  tc[:name],
                                        input: tc[:arguments] || {}
                                      }
                                    })
                    break if stream_closed

                    emit_event.call('content_block_delta', {
                                      type:  'content_block_delta',
                                      index: content_index,
                                      delta: {
                                        type:         'input_json_delta',
                                        partial_json: Legion::JSON.dump(tc[:arguments] || {})
                                      }
                                    })
                    break if stream_closed

                    emit_event.call('content_block_stop', { type: 'content_block_stop', index: content_index })
                    break if stream_closed

                    content_index += 1

                    # Emit server_tool_result for LegionIO tools
                    next unless is_server_tool

                    result = tc[:result]
                    next unless result

                    result_str = if result.is_a?(String)
                                   result
                                 else
                                   begin
                                     Legion::JSON.dump(result)
                                   rescue StandardError
                                     result.to_s
                                   end
                                 end
                    emit_event.call('content_block_start', {
                                      type:          'content_block_start',
                                      index:         content_index,
                                      content_block: { type: 'server_tool_result', id: tc[:id], content: [] }
                                    })
                    break if stream_closed

                    emit_event.call('content_block_delta', {
                                      type:  'content_block_delta',
                                      index: content_index,
                                      delta: { type: 'content_block_delta', content: [{ type: 'text', text: result_str }] }
                                    })
                    break if stream_closed

                    emit_event.call('content_block_stop', { type: 'content_block_stop', index: content_index })
                    break if stream_closed

                    content_index += 1
                  end
                  next if stream_closed

                  emit_event.call('message_delta', {
                                    type:  'message_delta',
                                    delta: { stop_reason: stop_reason, stop_sequence: nil },
                                    usage: {
                                      input_tokens:  translator.token_count(tokens, :input),
                                      output_tokens: translator.token_count(tokens, :output)
                                    }
                                  })
                  next if stream_closed

                  emit_event.call('message_stop', { type: 'message_stop' })
                  log_api_completion_summary(
                    namespace:         'anthropic',
                    request_id:        request_id,
                    pipeline_response: pipeline_response,
                    stream:            true,
                    started_at:        request_started_at,
                    tool_calls:        tool_calls,
                    stop_reason:       stop_reason
                  )
                rescue IOError, Errno::EPIPE, *(defined?(Puma) ? [Puma::ConnectionError] : [])
                  # Client disconnected — exit cleanly without blowing up Puma
                rescue StandardError => e
                  handle_exception(e, level: :error, handled: false, operation: 'llm.ns.anthropic.messages.stream', request_id: request_id)
                end
              else
                pipeline_response = executor.call
                formatted = Legion::LLM::API::Translators::AnthropicResponse.format(
                  pipeline_response, model: model, request_id: request_id
                )
                log_api_completion_summary(
                  namespace:         'anthropic',
                  request_id:        request_id,
                  pipeline_response: pipeline_response,
                  stream:            false,
                  started_at:        request_started_at,
                  tool_calls:        Legion::LLM::API::Translators::AnthropicResponse.extract_tool_calls(pipeline_response),
                  stop_reason:       Legion::LLM::API::Translators::AnthropicResponse.format_stop_reason(pipeline_response)
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
                # Model is optional for auto-routing — the executor will select a default
                missing << 'messages' if body[:messages].nil? || !body[:messages].is_a?(Array) || body[:messages].empty?
                missing << 'max_tokens' if body[:max_tokens].nil?
                return if missing.empty?

                halt 400, { 'Content-Type' => 'application/json' },
                     Legion::JSON.dump({ type: 'error', error: { type: 'invalid_request_error', message: "missing required fields: #{missing.join(', ')}" } })
              end

              def extract_fallback_text(pipeline_response)
                msg = pipeline_response.message
                text = msg.is_a?(Hash) ? (msg[:content] || msg['content']).to_s : ''
                text.to_s.strip
              end

              def extract_chunk_text(chunk)
                return chunk.to_s unless chunk.respond_to?(:content)

                chunk.content.to_s
              rescue StandardError
                chunk.to_s
              end

              def emit_thinking_signature_delta(emit_event, index, signature)
                return if signature.to_s.empty?

                emit_event.call('content_block_delta', {
                                  type:  'content_block_delta',
                                  index: index,
                                  delta: { type: 'signature_delta', signature: signature.to_s }
                                })
              end

              def extract_chunk_thinking_payload(chunk)
                return nil unless chunk.respond_to?(:thinking)

                thinking = chunk.thinking
                return nil if thinking.nil?

                if thinking.is_a?(Hash)
                  normalized = thinking.transform_keys { |key| key.respond_to?(:to_sym) ? key.to_sym : key }
                  content = normalized[:content] || normalized[:text] || normalized[:thinking]
                  signature = normalized[:signature]
                else
                  content = thinking.respond_to?(:content) ? thinking.content : nil
                  content = thinking.text if content.nil? && thinking.respond_to?(:text)
                  content = thinking unless thinking.respond_to?(:content) || thinking.respond_to?(:text)
                  signature = thinking.respond_to?(:signature) ? thinking.signature : nil
                end

                content = content.to_s unless content.nil?
                signature = signature.to_s unless signature.nil?
                return nil if content.to_s.empty? && signature.to_s.empty?

                { content: content, signature: signature }.compact
              rescue StandardError
                nil
              end
            end
          end
        end
      end
    end
  end
end
