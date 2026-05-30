# frozen_string_literal: true

require 'securerandom'
require 'legion/logging/helper'
require 'legion/llm/types'
require 'legion/llm/api/namespaces/helpers'
require 'legion/llm/api/translators/openai_request'
require 'legion/llm/api/translators/openai_response'

module Legion
  module LLM
    module API
      module Namespaces
        module OpenAI
          module Chat
            module Completions
              extend Legion::Logging::Helper

              def self.registered(app) # rubocop:disable Metrics/AbcSize,Metrics/MethodLength
                log.debug('[llm][api][namespaces][openai][chat] registering routes')

                # rubocop:disable Metrics/BlockLength
                app.post '/v1/chat/completions' do
                  require_llm!
                  body = parse_request_body

                  unless body[:messages].is_a?(Array) && !body[:messages].empty?
                    return openai_error('messages is required and must be a non-empty array',
                                        type: 'invalid_request_error', code: nil, status_code: 400)
                  end

                  request_id = body[:request_id] || SecureRandom.uuid
                  normalized = Legion::LLM::API::Translators::OpenAIRequest.normalize(body)
                  model      = normalized[:model] || Legion::LLM::Settings.value(:default_model) || 'default'
                  streaming  = normalized[:stream] == true
                  include_reasoning = body[:include_reasoning] == true || body[:include_thinking] == true
                  tool_decls = Completions.build_tool_declarations(normalized[:tools])

                  ext = Completions.extract_extended_fields(body, env)

                  msg_count = normalized[:messages].size
                  msg_chars = normalized[:messages].sum { |m| m[:content].to_s.length }
                  log.info('[llm][api][namespaces][openai][chat] action=accepted ' \
                           "request_id=#{request_id} model=#{model} stream=#{streaming} " \
                           "messages=#{msg_count} chars=#{msg_chars} tools=#{tool_decls.size} " \
                           "conversation_id=#{ext[:conversation_id] || 'none'} tier=#{ext[:tier] || 'auto'}")

                  Completions.gaia_ingest(body[:messages], request_id, identity_canonical_name(env))

                  effective_caller = build_server_caller(
                    source: 'openai_compat', path: request.path, env: env,
                    caller_context: ext[:caller_context]
                  )

                  inference_request = Completions.build_inference_request(
                    request_id: request_id, normalized: normalized, model: model,
                    tool_declarations: tool_decls, caller: effective_caller,
                    streaming: streaming, ext: ext
                  )
                  executor = Legion::LLM::Inference::Executor.new(inference_request)

                  if streaming
                    content_type 'text/event-stream'
                    headers 'Cache-Control' => 'no-cache', 'Connection' => 'keep-alive', 'X-Accel-Buffering' => 'no'
                    stream do |out|
                      pipeline_response = executor.call_stream do |chunk|
                        Completions.emit_reasoning_delta(out, chunk, model, request_id, include_reasoning)
                        text = chunk.respond_to?(:content) ? chunk.content.to_s : chunk.to_s
                        next if text.empty?

                        chunk_obj = Legion::LLM::API::Translators::OpenAIResponse.format_stream_chunk(
                          text, model: model, request_id: request_id
                        )
                        out << "data: #{Legion::JSON.dump(chunk_obj)}\n\n"
                      end

                      routing     = pipeline_response.routing || {}
                      final_model = (routing[:model] || routing['model'] || model).to_s
                      tool_calls  = Legion::LLM::API::Translators::OpenAIResponse.build_tool_calls(pipeline_response)

                      tool_calls.each_with_index do |tc, idx|
                        tc_chunk = Legion::LLM::API::Translators::OpenAIResponse.format_stream_tool_call_chunk(
                          tc, model: final_model, request_id: request_id, index: idx
                        )
                        out << "data: #{Legion::JSON.dump(tc_chunk)}\n\n"
                      end

                      done_chunk = Legion::LLM::API::Translators::OpenAIResponse.format_stream_chunk(
                        nil, model: final_model, request_id: request_id,
                        finish_reason: tool_calls.empty? ? 'stop' : 'tool_calls'
                      )
                      Completions.append_usage_stats(done_chunk, pipeline_response, include_reasoning)
                      out << "data: #{Legion::JSON.dump(done_chunk)}\n\n"
                      out << "data: [DONE]\n\n"
                      log.info('[llm][api][namespaces][openai][chat] action=stream_complete ' \
                               "request_id=#{request_id} model=#{final_model} " \
                               "tool_calls=#{tool_calls.size} finish_reason=#{tool_calls.empty? ? 'stop' : 'tool_calls'}")
                    rescue StandardError => e
                      handle_exception(e, level: :error, handled: false,
                                       operation: 'llm.api.namespaces.openai.chat.stream', request_id: request_id)
                      out << "data: #{Legion::JSON.dump({ error: { message: e.message, type: 'server_error' } })}\n\n"
                      out << "data: [DONE]\n\n"
                    end
                  else
                    pipeline_response = executor.call
                    response_body = Legion::LLM::API::Translators::OpenAIResponse.format_chat_completion(
                      pipeline_response, model: model, request_id: request_id,
                      include_reasoning: include_reasoning
                    )
                    log.info("[llm][api][namespaces][openai][chat] action=complete request_id=#{request_id} " \
                             "model=#{response_body[:model]}")
                    content_type :json
                    status 200
                    Legion::JSON.dump(response_body)
                  end
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
                # rubocop:enable Metrics/BlockLength

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

              def self.extract_extended_fields(body, env)
                ctp = if env.key?('HTTP_X_LEGION_CLIENT_TOOL_PASSTHROUGH')
                        env['HTTP_X_LEGION_CLIENT_TOOL_PASSTHROUGH'] == 'true'
                      elsif [true, false].include?(body[:client_tool_passthrough])
                        body[:client_tool_passthrough]
                      end

                {
                  conversation_id:         env['HTTP_X_LEGION_CONVERSATION_ID'] || body[:conversation_id],
                  provider:                env['HTTP_X_LEGION_PROVIDER'] || body[:provider],
                  tier:                    env['HTTP_X_LEGION_TIER'] || body[:tier],
                  instance:                env['HTTP_X_LEGION_INSTANCE'] || body[:instance],
                  cwd:                     env['HTTP_X_LEGION_CWD'] || body[:cwd],
                  requested_tools:         body[:requested_tools] || [],
                  client_tool_passthrough: ctp,
                  caller_context:          body[:caller]
                }
              end

              def self.build_inference_request(request_id:, normalized:, model:, tool_declarations:, caller:, streaming:, ext:)
                extra = {}
                extra[:tier] = ext[:tier].to_sym if ext[:tier]
                extra[:cwd] = ext[:cwd] if ext[:cwd]

                metadata = { requested_tools: ext[:requested_tools] }
                metadata[:client_tool_passthrough] = ext[:client_tool_passthrough] unless ext[:client_tool_passthrough].nil?
                metadata[:client_tool_request_count] = normalized[:tools]&.size if normalized[:tools]&.any?

                Legion::LLM::Inference::Request.build(
                  id:              request_id,
                  messages:        normalized[:messages],
                  system:          normalized[:system],
                  routing:         { provider: ext[:provider], model: model, instance: ext[:instance] }.compact,
                  tools:           tool_declarations,
                  caller:          caller,
                  conversation_id: ext[:conversation_id],
                  metadata:        metadata.compact,
                  stream:          streaming,
                  cache:           { strategy: :default, cacheable: true },
                  extra:           extra.empty? ? {} : extra
                )
              end

              def self.build_tool_declarations(tools)
                return [] unless tools.is_a?(Array) && !tools.empty?

                tools.filter_map do |tool|
                  t = nil
                  t = tool.respond_to?(:transform_keys) ? tool.transform_keys(&:to_sym) : tool
                  next unless t[:name].to_s.length.positive?

                  Legion::LLM::Types::ToolDefinition.build(
                    name:        t[:name].to_s,
                    description: t[:description].to_s,
                    parameters:  t[:parameters] || {},
                    source:      { type: :client, executable: true }
                  )
                rescue StandardError => e
                  tool_name = t.is_a?(Hash) ? t[:name] : nil
                  log.warn("[llm][api][namespaces][openai][chat] build_tool failed name=#{tool_name} error=#{e.message}")
                  nil
                end
              end

              def self.emit_reasoning_delta(out, chunk, model, request_id, include_reasoning)
                return unless include_reasoning && chunk.respond_to?(:thinking)

                thinking_text = extract_thinking_text(chunk.thinking)
                return if thinking_text.empty?

                reasoning_chunk = Legion::LLM::API::Translators::OpenAIResponse.format_stream_delta_chunk(
                  { reasoning_content: thinking_text },
                  model: model, request_id: request_id
                )
                out << "data: #{Legion::JSON.dump(reasoning_chunk)}\n\n"
              end

              def self.append_usage_stats(done_chunk, pipeline_response, include_reasoning)
                return unless include_reasoning

                tokens = pipeline_response.tokens || {}
                oai = Legion::LLM::API::Translators::OpenAIResponse
                input_count = oai.extract_token_count(tokens, :input).to_i
                output_count = oai.extract_token_count(tokens, :output).to_i
                done_chunk[:usage] = {
                  prompt_tokens:     input_count,
                  completion_tokens: output_count,
                  total_tokens:      input_count + output_count
                }
              end

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

              def self.extract_thinking_text(value)
                return '' if value.nil?
                return value.to_s if value.is_a?(String)

                if value.is_a?(Hash)
                  text = value[:content] || value['content'] || value[:text] || value['text']
                  return text.to_s if text
                end

                return value.content.to_s if value.respond_to?(:content) && value.content
                return value.text.to_s if value.respond_to?(:text) && value.text

                value.to_s
              end
            end
          end
        end
      end
    end
  end
end
