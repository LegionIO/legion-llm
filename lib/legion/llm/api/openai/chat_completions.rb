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

          def self.registered(app) # rubocop:disable Metrics/AbcSize,Metrics/MethodLength
            log.debug('[llm][api][openai][chat_completions] registering POST /v1/chat/completions')

            app.post '/v1/chat/completions' do # rubocop:disable Metrics/BlockLength
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
              # Support reasoning/thinking tokens. Opt-in via `include_reasoning: true` in the
              # request body (mirrors the native API's `include_thinking` flag).
              include_reasoning = body[:include_reasoning] == true || body[:include_thinking] == true

              log.info("[llm][api][openai][chat_completions] action=accepted request_id=#{request_id} " \
                       "model=#{model} stream=#{streaming} reasoning=#{include_reasoning}")

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

                stream do |out| # rubocop:disable Metrics/BlockLength
                  pipeline_response = executor.call_stream do |chunk|
                    Legion::LLM::API::OpenAI::ChatCompletions.emit_reasoning_delta(
                      out, chunk, model, request_id, include_reasoning
                    )
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
                    tc_chunk = Legion::LLM::API::Translators::OpenAIResponse.format_stream_tool_call_chunk(
                      tool_call, model: final_model, request_id: request_id, index: index
                    )
                    out << "data: #{Legion::JSON.dump(tc_chunk)}\n\n"
                  end

                  done_chunk = Legion::LLM::API::Translators::OpenAIResponse.format_stream_chunk(
                    nil, model: final_model, request_id: request_id,
                    finish_reason: tool_calls.empty? ? 'stop' : 'tool_calls'
                  )
                  Legion::LLM::API::OpenAI::ChatCompletions.append_usage_stats(
                    done_chunk, pipeline_response, include_reasoning
                  )
                  out << "data: #{Legion::JSON.dump(done_chunk)}\n\n"
                  out << "data: [DONE]\n\n"
                  log.info("[llm][api][openai][chat_completions] action=stream_complete " \
                           "request_id=#{request_id} model=#{final_model}")
                rescue StandardError => e
                  handle_exception(e, level: :error, handled: false,
                                   operation: 'llm.api.openai.chat_completions.stream',
                                   request_id: request_id)
                  out << "data: #{Legion::JSON.dump({ error: { message: e.message, type: 'server_error' } })}\n\n"
                  out << "data: [DONE]\n\n"
                end
              else
                pipeline_response = executor.call
                response_body = Legion::LLM::API::Translators::OpenAIResponse.format_chat_completion(
                  pipeline_response, model: model, request_id: request_id,
                  include_reasoning: include_reasoning
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

            log.debug('[llm][api][openai][chat_completions] POST /v1/chat/completions registered')
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

          # Extract text content from a thinking chunk value.
          # Handles the various shapes the chunk.thinking field can take:
          #   - Hash with :content or :text key
          #   - Object with .content or .text method
          #   - Raw string
          def self.extract_chunk_text(value)
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

          # Emit a reasoning_content delta chunk if the streaming chunk contains thinking.
          def self.emit_reasoning_delta(out, chunk, model, request_id, include_reasoning)
            return unless include_reasoning && chunk.respond_to?(:thinking)

            thinking_text = extract_chunk_text(chunk.thinking)
            return if thinking_text.empty?

            reasoning_chunk = Legion::LLM::API::Translators::OpenAIResponse.format_stream_delta_chunk(
              { reasoning_content: thinking_text },
              model: model, request_id: request_id
            )
            out << "data: #{Legion::JSON.dump(reasoning_chunk)}\n\n"
          end

          # Append usage stats to the done chunk when reasoning is enabled.
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
        end
      end
    end
  end
end
