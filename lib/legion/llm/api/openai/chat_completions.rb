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

              request_id = body[:request_id] || SecureRandom.uuid
              normalized = Legion::LLM::API::Translators::OpenAIRequest.normalize(body)
              model = normalized[:model] || Legion::LLM::Settings.value(:default_model) || 'default'
              streaming = normalized[:stream] == true
              include_reasoning = body[:include_reasoning] == true || body[:include_thinking] == true

              # ── Extended fields + pipeline request (parity with native) ─────────
              ext = Legion::LLM::API::OpenAI::ChatCompletions.extract_extended_fields(body, env)

              log.info('[llm][api][openai][chat_completions] action=accepted ' \
                       "request_id=#{request_id} model=#{model} stream=#{streaming} " \
                       "conversation_id=#{ext[:conversation_id] || 'none'} tier=#{ext[:tier] || 'auto'}")

              tool_declarations = Legion::LLM::API::OpenAI::ChatCompletions.build_openai_tool_classes(normalized[:tools])

              # ── Gaia ingest (mirrors native endpoint pre-pipeline awareness) ────
              Legion::LLM::API::OpenAI::ChatCompletions.gaia_ingest(
                body[:messages], request_id, identity_canonical_name(env)
              )

              effective_caller = build_server_caller(
                source: 'openai_compat', path: request.path, env: env,
                caller_context: ext[:caller_context]
              )

              inference_request = Legion::LLM::API::OpenAI::ChatCompletions.build_inference_request(
                request_id: request_id, normalized: normalized, model: model,
                tool_declarations: tool_declarations, caller: effective_caller,
                streaming: streaming, ext: ext
              )

              executor = Legion::LLM::Inference::Executor.new(inference_request)

              if streaming
                content_type 'text/event-stream'
                headers 'Cache-Control'     => 'no-cache',
                        'Connection'        => 'keep-alive',
                        'X-Accel-Buffering' => 'no'

                stream do |out|
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
                    nil,
                    model:         final_model,
                    request_id:    request_id,
                    finish_reason: tool_calls.empty? ? 'stop' : 'tool_calls',
                    usage:         {
                      prompt_tokens:     Legion::LLM::API::Translators::OpenAIResponse.extract_token_count(pipeline_response.tokens, :input),
                      completion_tokens: Legion::LLM::API::Translators::OpenAIResponse.extract_token_count(pipeline_response.tokens, :output),
                      total_tokens:      Legion::LLM::API::Translators::OpenAIResponse.extract_token_count(pipeline_response.tokens, :input).to_i +
                                         Legion::LLM::API::Translators::OpenAIResponse.extract_token_count(pipeline_response.tokens, :output).to_i
                    }
                  )
                  Legion::LLM::API::OpenAI::ChatCompletions.append_usage_stats(
                    done_chunk, pipeline_response, include_reasoning
                  )
                  out << "data: #{Legion::JSON.dump(done_chunk)}\n\n"
                  out << "data: [DONE]\n\n"
                  log.info('[llm][api][openai][chat_completions] action=stream_complete ' \
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
          end

          # Extract extended pipeline fields from body + X-Legion-* headers.
          # Headers take precedence for scalar values; body for complex objects.
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

          # Build the Inference::Request with full pipeline field set.
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

          # Pre-pipeline Gaia ingest — mirrors the native endpoint's awareness update.
          # Feeds the latest user prompt into Gaia so advisory/context is fresh.
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
            log.debug("[llm][api][openai][chat_completions] action=gaia_ingest request_id=#{request_id}")
          rescue StandardError => e
            log.warn("[llm][api][openai][chat_completions] gaia_ingest failed: #{e.message}")
          end
        end
      end
    end
  end
end
