# frozen_string_literal: true

require 'securerandom'
require 'legion/logging/helper'
require 'legion/llm/types'
require_relative '../translators/anthropic_request'
require_relative '../translators/anthropic_response'

module Legion
  module LLM
    module API
      module Anthropic
        module Messages
          extend Legion::Logging::Helper

          def self.registered(app) # rubocop:disable Metrics/AbcSize
            log.debug('[llm][api][anthropic][messages] registering POST /v1/messages')

            app.post '/v1/messages' do
              require_llm!

              body = parse_request_body
              validate_required!(body, :model, :messages, :max_tokens)

              request_id = body[:request_id] || "msg_#{SecureRandom.hex(12)}"
              log.debug("[llm][api][anthropic][messages] action=received request_id=#{request_id} model=#{body[:model]}")

              normalized = Legion::LLM::API::Translators::AnthropicRequest.normalize(body)
              streaming  = normalized[:stream] == true && request.preferred_type.to_s.include?('text/event-stream')
              log.debug("[llm][api][anthropic][messages] action=normalized stream=#{streaming} messages=#{normalized[:messages].size}")

              require 'legion/llm/inference/request'  unless defined?(Legion::LLM::Inference::Request)
              require 'legion/llm/inference/executor' unless defined?(Legion::LLM::Inference::Executor)

              pipeline_request = Legion::LLM::Inference::Request.build(
                id:       request_id,
                messages: normalized[:messages],
                system:   normalized[:system],
                routing:  normalized[:routing],
                tools:    build_tool_classes(normalized[:tools] || []),
                caller:   build_server_caller(source: 'anthropic_compat', path: request.path, env: env),
                stream:   streaming,
                thinking: body[:thinking],
                cache:    { strategy: :default, cacheable: true }
              )

              executor = Legion::LLM::Inference::Executor.new(pipeline_request)
              model    = body[:model]

              if streaming
                content_type 'text/event-stream'
                headers 'Cache-Control'     => 'no-cache',
                        'Connection'        => 'keep-alive',
                        'X-Accel-Buffering' => 'no'

                stream do |out|
                  full_text = +''
                  text_delta_lines = [] # buffer in-stream deltas until we know if tool calls exist

                  pipeline_response = executor.call_stream do |chunk|
                    # ANNOTATE (G3/L4-family, legacy tree): the provider
                    # boundary yields Canonical::Chunk — for a canonical
                    # chunk the .to_s fallback leaks the chunk's Ruby
                    # inspect string to the client as text. The flat legacy
                    # API tree (register_legacy) is a coordinated-wave
                    # deletion surface; this chunk read is fixed with the
                    # tree, not inline.
                    text = chunk.respond_to?(:content) ? chunk.content.to_s : chunk.to_s
                    next if text.empty?

                    full_text << text
                    delta_event = Legion::LLM::API::Translators::AnthropicResponse.format_chunk(text)
                    text_delta_lines << "event: content_block_delta\ndata: #{Legion::JSON.dump(delta_event)}\n\n"
                  end

                  events = Legion::LLM::API::Translators::AnthropicResponse.streaming_events(
                    pipeline_response,
                    model:      model,
                    request_id: request_id,
                    full_text:  full_text
                  )

                  # If tool calls are present and the text is just JSON arguments,
                  # suppress the in-stream text deltas so the client only sees
                  # tool_use content blocks — not text deltas of raw JSON.
                  if Legion::LLM::API::Translators::AnthropicResponse.text_looks_like_tool_json?(full_text)
                    pipeline_tools = pipeline_response.respond_to?(:tools) ? Array(pipeline_response.tools) : []
                    text_delta_lines.clear if pipeline_tools.any?
                  end

                  text_delta_lines.each { |line| out << line }

                  events.each do |event_name, payload|
                    next if event_name == 'content_block_delta'

                    out << "event: #{event_name}\ndata: #{Legion::JSON.dump(payload)}\n\n"
                  end

                  routing = pipeline_response.respond_to?(:routing) ? (pipeline_response.routing || {}) : {}
                  log.info(
                    "[llm][api][anthropic][messages] action=stream_complete request_id=#{request_id} " \
                    "model=#{routing[:model] || routing['model'] || model} stream=true"
                  )
                rescue StandardError => e
                  handle_exception(e, level: :error, handled: false, operation: 'llm.api.anthropic.messages.stream', request_id: request_id)
                  out << "event: error\ndata: #{Legion::JSON.dump({ type: 'error', error: { type: 'api_error', message: e.message } })}\n\n"
                end
              else
                pipeline_response = executor.call
                formatted = Legion::LLM::API::Translators::AnthropicResponse.format(
                  pipeline_response,
                  model:      model,
                  request_id: request_id
                )

                routing = pipeline_response.respond_to?(:routing) ? (pipeline_response.routing || {}) : {}
                log.info(
                  "[llm][api][anthropic][messages] action=completed request_id=#{request_id} " \
                  "model=#{routing[:model] || routing['model'] || model} stream=false"
                )

                content_type :json
                status 200
                Legion::JSON.dump(formatted)
              end
            rescue Legion::LLM::AuthError => e
              handle_exception(e, level: :error, handled: true, operation: 'llm.api.anthropic.messages.auth')
              content_type :json
              status 401
              Legion::JSON.dump({ type: 'error', error: { type: 'authentication_error', message: e.message } })
            rescue Legion::LLM::RateLimitError => e
              handle_exception(e, level: :error, handled: true, operation: 'llm.api.anthropic.messages.rate_limit')
              content_type :json
              status 429
              Legion::JSON.dump({ type: 'error', error: { type: 'rate_limit_error', message: e.message } })
            rescue Legion::LLM::ContextOverflow => e
              handle_exception(e, level: :error, handled: true, operation: 'llm.api.anthropic.messages.context')
              content_type :json
              status 400
              Legion::JSON.dump({ type: 'error', error: { type: 'invalid_request_error', message: e.message } })
            rescue Legion::LLM::ProviderDown, Legion::LLM::ProviderError => e
              handle_exception(e, level: :error, handled: true, operation: 'llm.api.anthropic.messages.provider')
              content_type :json
              status 529
              Legion::JSON.dump({ type: 'error', error: { type: 'overloaded_error', message: e.message } })
            rescue StandardError => e
              handle_exception(e, level: :error, handled: false, operation: 'llm.api.anthropic.messages')
              content_type :json
              status 500
              Legion::JSON.dump({ type: 'error', error: { type: 'api_error', message: e.message } })
            end

            log.debug('[llm][api][anthropic][messages] POST /v1/messages registered')
          end

          def self.build_tool_classes(tool_specs)
            return [] if tool_specs.empty?

            tool_specs.filter_map do |spec|
              next unless spec.is_a?(Hash) && spec[:name].to_s.length.positive?

              tname  = spec[:name].to_s
              tdesc  = spec[:description].to_s
              tschema = spec[:parameters] || {}

              begin
                Legion::LLM::Types::ToolDefinition.build(
                  name:        tname,
                  description: tdesc,
                  parameters:  tschema,
                  source:      { type: :client, executable: true }
                )
              rescue StandardError => e
                log.warn("[llm][api][anthropic][messages] build_tool_classes failed name=#{tname} error=#{e.message}")
                nil
              end
            end
          end

          private_class_method :build_tool_classes
        end
      end
    end
  end
end
