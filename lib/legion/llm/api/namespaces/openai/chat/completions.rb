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

                  request_id = SecureRandom.uuid
                  normalized = Legion::LLM::API::Translators::OpenAIRequest.normalize(body)
                  model      = normalized[:model] || Legion::LLM::Settings.value(:default_model) || 'default'
                  streaming  = normalized[:stream] == true
                  tool_decls = Completions.build_tool_declarations(normalized[:tools])

                  log.info("[llm][api][namespaces][openai][chat] action=accepted request_id=#{request_id} model=#{model} stream=#{streaming}")

                  inference_request = Legion::LLM::Inference::Request.build(
                    id:       request_id,
                    messages: normalized[:messages],
                    system:   normalized[:system],
                    routing:  { model: model },
                    tools:    tool_decls,
                    caller:   build_server_caller(source: 'openai_compat', path: request.path, env: env),
                    stream:   streaming,
                    cache:    { strategy: :default, cacheable: true }
                  )
                  executor = Legion::LLM::Inference::Executor.new(inference_request)

                  if streaming
                    content_type 'text/event-stream'
                    headers 'Cache-Control' => 'no-cache', 'Connection' => 'keep-alive', 'X-Accel-Buffering' => 'no'
                    stream do |out|
                      pipeline_response = executor.call_stream do |chunk|
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
                        out << "data: #{Legion::JSON.dump(Legion::LLM::API::Translators::OpenAIResponse.format_stream_tool_call_chunk(tc, model: final_model,
request_id: request_id, index: idx))}\n\n"
                      end

                      done_chunk = Legion::LLM::API::Translators::OpenAIResponse.format_stream_chunk(
                        nil, model: final_model, request_id: request_id,
                        finish_reason: tool_calls.empty? ? 'stop' : 'tool_calls'
                      )
                      out << "data: #{Legion::JSON.dump(done_chunk)}\n\n"
                      out << "data: [DONE]\n\n"
                      log.info("[llm][api][namespaces][openai][chat] action=stream_complete request_id=#{request_id} model=#{final_model}")
                    rescue StandardError => e
                      handle_exception(e, level: :error, handled: false, operation: 'llm.api.namespaces.openai.chat.stream', request_id: request_id)
                      out << "data: #{Legion::JSON.dump({ error: { message: e.message, type: 'server_error' } })}\n\n"
                      out << "data: [DONE]\n\n"
                    end
                  else
                    pipeline_response = executor.call
                    response_body = Legion::LLM::API::Translators::OpenAIResponse.format_chat_completion(
                      pipeline_response, model: model, request_id: request_id
                    )
                    log.info("[llm][api][namespaces][openai][chat] action=complete request_id=#{request_id}")
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

              def self.build_tool_declarations(tools)
                return [] unless tools.is_a?(Array) && !tools.empty?

                tools.filter_map do |tool|
                  t = tool.respond_to?(:transform_keys) ? tool.transform_keys(&:to_sym) : tool
                  next unless t[:name].to_s.length.positive?

                  Legion::LLM::Types::ToolDefinition.build(
                    name:        t[:name].to_s,
                    description: t[:description].to_s,
                    parameters:  t[:parameters] || {},
                    source:      { type: :client, executable: true }
                  )
                rescue StandardError => e
                  Legion::Logging::Helper.log.warn("[llm][api][namespaces][openai][chat] build_tool failed name=#{t[:name]} error=#{e.message}")
                  nil
                end
              end
            end
          end
        end
      end
    end
  end
end
