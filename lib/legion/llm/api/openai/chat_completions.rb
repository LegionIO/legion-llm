# frozen_string_literal: true

require 'securerandom'
require 'legion/logging/helper'
require 'legion/llm/types'

module Legion
  module LLM
    module API
      module OpenAI
        module ChatCompletions
          extend Legion::Logging::Helper

          def self.registered(app)
            log.debug('[llm][api][openai][chat_completions] registering POST /v1/chat/completions + /api/llm/inference/v1/chat/completions')

            handler = build_handler

            app.post('/v1/chat/completions') { instance_exec(&handler) }
            app.post('/api/llm/inference/v1/chat/completions') { instance_exec(&handler) }

            log.debug('[llm][api][openai][chat_completions] routes registered')
          end

          def self.build_handler # rubocop:disable Metrics/MethodLength,Metrics/AbcSize
            proc do # rubocop:disable Metrics/BlockLength
              require_llm!
              body = parse_request_body

              unless body[:messages].is_a?(Array) && !body[:messages].empty?
                halt 400, { 'Content-Type' => 'application/json' },
                     Legion::JSON.dump({ error: { message: 'messages is required and must be a non-empty array',
                                                  type: 'invalid_request_error', param: 'messages', code: nil } })
              end

              request_id = SecureRandom.uuid
              normalized = Legion::LLM::API::Translators::OpenAIRequest.normalize(body)
              model = normalized[:model] || Legion::LLM::Settings.value(:default_model) || 'default'
              streaming = normalized[:stream] == true

              log.info("[llm][api][openai][chat_completions] action=accepted request_id=#{request_id} model=#{model} stream=#{streaming}")

              tool_declarations = Legion::LLM::API::OpenAI::ChatCompletions.build_openai_tool_classes(normalized[:tools])

              effective_caller = build_server_caller(source: 'openai_compat', path: request.path, env: env)

              inference_request = Legion::LLM::Inference::Request.build(
                id:       request_id,
                messages: normalized[:messages],
                system:   normalized[:system],
                routing:  { model: model },
                tools:    tool_declarations,
                caller:   effective_caller,
                stream:   streaming,
                cache:    { strategy: :default, cacheable: true }
              )

              executor = Legion::LLM::Inference::Executor.new(inference_request)

              if streaming
                content_type 'text/event-stream'
                headers 'Cache-Control'     => 'no-cache',
                        'Connection'        => 'keep-alive',
                        'X-Accel-Buffering' => 'no'

                stream do |out|
                  pipeline_response = executor.call_stream do |chunk|
                    text = chunk.respond_to?(:content) ? chunk.content.to_s : chunk.to_s
                    next if text.empty?

                    chunk_obj = Legion::LLM::API::Translators::OpenAIResponse.format_stream_chunk(
                      text, model: model, request_id: request_id
                    )
                    out << "data: #{Legion::JSON.dump(chunk_obj)}\n\n"
                  end

                  routing = pipeline_response.routing || {}
                  final_model = (routing[:model] || routing['model'] || model).to_s
                  tool_calls = Legion::LLM::API::Translators::OpenAIResponse.build_tool_calls(pipeline_response)

                  tool_calls.each_with_index do |tool_call, index|
                    out << "data: #{Legion::JSON.dump(Legion::LLM::API::Translators::OpenAIResponse.format_stream_tool_call_chunk(
                                                        tool_call,
                                                        model:      final_model,
                                                        request_id: request_id,
                                                        index:      index
                                                      ))}\n\n"
                  end

                  done_chunk = Legion::LLM::API::Translators::OpenAIResponse.format_stream_chunk(
                    nil,
                    model:         final_model,
                    request_id:    request_id,
                    finish_reason: tool_calls.empty? ? 'stop' : 'tool_calls'
                  )
                  out << "data: #{Legion::JSON.dump(done_chunk)}\n\n"
                  out << "data: [DONE]\n\n"

                  log.info("[llm][api][openai][chat_completions] action=stream_complete request_id=#{request_id} model=#{final_model}")
                rescue StandardError => e
                  handle_exception(e, level: :error, handled: false, operation: 'llm.api.openai.chat_completions.stream', request_id: request_id)
                  out << "data: #{Legion::JSON.dump({ error: { message: e.message, type: 'server_error' } })}\n\n"
                  out << "data: [DONE]\n\n"
                end
              else
                pipeline_response = executor.call
                response_body = Legion::LLM::API::Translators::OpenAIResponse.format_chat_completion(
                  pipeline_response, model: model, request_id: request_id
                )

                log.info("[llm][api][openai][chat_completions] action=complete request_id=#{request_id} model=#{response_body[:model]}")
                content_type :json
                status 200
                Legion::JSON.dump(response_body)
              end
            rescue Legion::LLM::AuthError => e
              handle_exception(e, level: :error, handled: true, operation: 'llm.api.openai.chat_completions.auth')
              halt 401, { 'Content-Type' => 'application/json' },
                   Legion::JSON.dump({ error: { message: e.message, type: 'authentication_error' } })
            rescue Legion::LLM::RateLimitError => e
              handle_exception(e, level: :warn, handled: true, operation: 'llm.api.openai.chat_completions.rate_limit')
              halt 429, { 'Content-Type' => 'application/json' },
                   Legion::JSON.dump({ error: { message: e.message, type: 'requests', code: 'rate_limit_exceeded' } })
            rescue Legion::LLM::ProviderDown, Legion::LLM::ProviderError => e
              handle_exception(e, level: :error, handled: true, operation: 'llm.api.openai.chat_completions.provider')
              halt 502, { 'Content-Type' => 'application/json' },
                   Legion::JSON.dump({ error: { message: e.message, type: 'server_error' } })
            rescue StandardError => e
              handle_exception(e, level: :error, handled: false, operation: 'llm.api.openai.chat_completions')
              halt 500, { 'Content-Type' => 'application/json' },
                   Legion::JSON.dump({ error: { message: e.message, type: 'server_error' } })
            end
          end

          def self.build_openai_tool_classes(tools)
            return [] if tools.nil? || !tools.is_a?(Array) || tools.empty?

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
              handle_exception(e, level: :warn, handled: true, operation: "llm.api.openai.build_tool.#{tool_name || 'unknown'}")
              nil
            end
          end
        end
      end
    end
  end
end
