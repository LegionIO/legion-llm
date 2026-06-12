# frozen_string_literal: true

require 'securerandom'
require 'time'
require 'legion/logging/helper'
require 'legion/extensions/llm'
require 'legion/llm/types'
require 'legion/llm/inference/request'

module Legion
  module LLM
    module API
      module ClientTranslators
        # OpenAI /v1/chat/completions client translator.
        #
        # Per Phase 5: parse_request → Canonical::Request, format_response →
        # chat.completion shape, format_error, events emitter for the chat
        # completion SSE format (data: chunk\n\n + data: [DONE]).
        class OpenAIChat
          extend Legion::Logging::Helper
          include Legion::Logging::Helper

          Canonical = Legion::Extensions::Llm::Canonical

          FINISH_REASON_MAP = {
            end_turn:       'stop',
            tool_use:       'tool_calls',
            max_tokens:     'length',
            stop_sequence:  'stop',
            content_filter: 'content_filter',
            error:          'stop',
            pause_turn:     'tool_calls'
          }.freeze

          # G24 — declares which execution-proxy contract shape this translator
          # surfaces. Consumed by the lex-llm conformance shared examples.
          def g24_format
            :openai_chat
          end

          def parse_request(body, env = {})
            log.debug('[llm][client_translator][openai_chat] action=parse_request')
            body = symbolize(body)

            messages, system = extract_messages_and_system(body[:messages] || [])
            tools = build_tools(body[:tools])
            params = extract_params(body)
            external = external_refs(body, env)

            Canonical::Request.build(
              id:              body[:request_id] || env['HTTP_X_CLIENT_REQUEST_ID'] || SecureRandom.uuid,
              messages:        messages,
              system:          system,
              tools:           tools,
              params:          params,
              stream:          body[:stream] == true,
              conversation_id: env['HTTP_X_LEGION_CONVERSATION_ID'] || body[:conversation_id],
              routing:         { model: body[:model], provider: env['HTTP_X_LEGION_PROVIDER'] || body[:provider],
                                 instance: env['HTTP_X_LEGION_INSTANCE'] || body[:instance] }.compact,
              metadata:        {
                tier:                    env['HTTP_X_LEGION_TIER'] || body[:tier],
                cwd:                     env['HTTP_X_LEGION_CWD'] || body[:cwd],
                requested_tools:         body[:requested_tools] || [],
                client_tool_passthrough: extract_client_tool_passthrough(body, env),
                caller_context:          body[:caller],
                include_reasoning:       body[:include_reasoning] != false && body[:include_thinking] != false,
                external_refs:           external
              }.compact
            )
          end

          def build_inference_request(canonical_request, request_id:, server_caller:, modality: nil)
            tool_defs = build_tool_definitions(canonical_request.tools)

            extra = {}
            tier = canonical_request.metadata[:tier]
            cwd = canonical_request.metadata[:cwd]
            extra[:tier] = tier.to_sym if tier
            extra[:cwd] = cwd if cwd

            metadata = { requested_tools: canonical_request.metadata[:requested_tools] || [] }
            metadata[:client_tool_passthrough] = canonical_request.metadata[:client_tool_passthrough] unless canonical_request.metadata[:client_tool_passthrough].nil?
            metadata[:client_tool_request_count] = canonical_request.tools&.size if canonical_request.tools&.any?

            messages = inference_messages(canonical_request.messages)

            Legion::LLM::Inference::Request.build(
              id:              request_id,
              messages:        messages,
              system:          canonical_request.system,
              routing:         canonical_request.routing,
              tools:           tool_defs,
              caller:          server_caller,
              conversation_id: canonical_request.conversation_id,
              metadata:        metadata.compact,
              stream:          canonical_request.stream == true,
              modality:        modality,
              cache:           { strategy: :default, cacheable: true },
              extra:           extra.empty? ? {} : extra
            )
          end

          def format_response(pipeline_response, model:, request_id:, include_reasoning: false)
            request_id ||= SecureRandom.uuid
            routing = pipeline_response.respond_to?(:routing) ? pipeline_response.routing || {} : {}
            tokens = pipeline_response.respond_to?(:tokens) ? pipeline_response.tokens || {} : {}
            raw_msg = pipeline_response.respond_to?(:message) ? pipeline_response.message : nil
            content = raw_msg.is_a?(Hash) ? (raw_msg[:content] || raw_msg['content']) : raw_msg.to_s
            stop_reason = pipeline_response.respond_to?(:stop) ? pipeline_response.stop&.dig(:reason)&.to_s : nil

            actionable_tool_calls = build_tool_calls(pipeline_response)
            resolved_model = (routing[:model] || routing['model'] || model).to_s

            # G24 — server-executed tools are not actionable. When all tool
            # calls were server-resolved, finish_reason is 'stop' (not
            # 'tool_calls') and the model's text content is the only
            # client-visible turn. The server-resolved exchange is recorded
            # in the conversation history (via the executor's tool loop),
            # not on this response.
            finish_reason = actionable_tool_calls.empty? ? map_finish_reason(stop_reason) : 'tool_calls'

            content = nil if actionable_tool_calls.any? && content_looks_like_tool_json?(content)

            message_body = { role: 'assistant', content: content }
            message_body[:tool_calls] = actionable_tool_calls unless actionable_tool_calls.empty?

            if include_reasoning && pipeline_response.respond_to?(:thinking) && pipeline_response.thinking
              text = extract_thinking_text(pipeline_response.thinking)
              message_body[:reasoning_content] = text unless text.empty?
            end

            input = token_value(tokens, :input, :input_tokens).to_i
            output = token_value(tokens, :output, :output_tokens).to_i

            {
              id:      "chatcmpl-#{request_id.delete('-')}",
              object:  'chat.completion',
              created: Time.now.to_i,
              model:   resolved_model,
              choices: [{ index: 0, message: message_body, finish_reason: finish_reason }],
              usage:   { prompt_tokens: input, completion_tokens: output, total_tokens: input + output }
            }
          end

          def format_error(error, status_code: 500, type: 'server_error', code: nil)
            body = { error: { message: error.respond_to?(:message) ? error.message : error.to_s, type: type } }
            body[:error][:code] = code if code
            [status_code, body]
          end

          def events_emitter(out, request_id:, model:, conv_id: nil, include_reasoning: true)
            Events.new(out: out, request_id: request_id, model: model.to_s, conv_id: conv_id, include_reasoning: include_reasoning)
          end

          def format_chunk(canonical_chunk)
            return nil if canonical_chunk.nil?

            case canonical_chunk.type
            when :text_delta
              chunk_envelope({ content: canonical_chunk.delta.to_s })
            when :thinking_delta
              chunk_envelope({ reasoning_content: canonical_chunk.delta.to_s })
            when :tool_call_delta
              tc = canonical_chunk.tool_call
              args = tc.respond_to?(:arguments) ? tc.arguments : {}
              chunk_envelope({
                               tool_calls: [{
                                 index:    canonical_chunk.block_index || 0,
                                 id:       tc.respond_to?(:id) ? tc.id : nil,
                                 type:     'function',
                                 function: {
                                   name:      tc.respond_to?(:name) ? tc.name.to_s : '',
                                   arguments: args.is_a?(String) ? args : Legion::JSON.dump(args)
                                 }
                               }]
                             })
            when :done
              { object: 'chat.completion.chunk', choices: [{ index: 0, delta: {}, finish_reason: 'stop' }] }
            end
          end

          # Events emitter for /v1/chat/completions streaming. Emits
          # `data: <chunk>\n\n` lines with a final `data: [DONE]\n\n`.
          class Events
            include Legion::Logging::Helper

            def initialize(out:, request_id:, model:, conv_id: nil, include_reasoning: true)
              @out = out
              @request_id = request_id
              @model = model
              @conv_id = conv_id
              @include_reasoning = include_reasoning
              @done_emitted = false
            end

            def on_start(model:, request_id:, input_tokens:)
              _ = model
              _ = request_id
              _ = input_tokens
              # Chat completions stream has no equivalent of "message_start";
              # initial role marker piggybacks on the first text delta.
            end

            def on_text_open(block_index:)
              _ = block_index
              # No explicit open in chat.completion.chunk format.
            end

            def on_text_delta(block_index:, text:)
              _ = block_index
              emit_chunk(delta_envelope({ content: text }))
            end

            def on_text_close(block_index:)
              _ = block_index
            end

            def on_thinking_open(block_index:)
              _ = block_index
            end

            def on_thinking_delta(block_index:, text:, signature:)
              _ = block_index
              _ = signature
              return unless @include_reasoning
              return if text.to_s.empty?

              emit_chunk(delta_envelope({ reasoning_content: text }))
            end

            def on_thinking_close(block_index:, signature:)
              _ = block_index
              _ = signature
            end

            def on_tool_call_open(block_index:, tool_call:, server_tool:)
              _ = server_tool
              # Send the initial tool_call with name. Index is 0-based across
              # this streaming response; chat.completion.chunk references it
              # by index in the delta.
              emit_chunk(delta_envelope({
                                          tool_calls: [{
                                            index:    block_index,
                                            id:       tool_call[:id],
                                            type:     'function',
                                            function: {
                                              name:      tool_call[:name].to_s,
                                              arguments: ''
                                            }
                                          }]
                                        }))
            end

            def on_tool_call_delta(block_index:, partial_arguments_json:)
              return if partial_arguments_json.to_s.empty?

              emit_chunk(delta_envelope({
                                          tool_calls: [{
                                            index:    block_index,
                                            function: { arguments: partial_arguments_json }
                                          }]
                                        }))
            end

            def on_tool_call_close(block_index:)
              _ = block_index
              # No close event in chat.completion.chunk; finish_reason
              # 'tool_calls' on the final done covers it.
            end

            def on_server_tool_result(block_index:, tool_call_id:, result_text:)
              _ = block_index
              _ = tool_call_id
              _ = result_text
              # Chat completions has no inline server tool result event. The
              # follow-up turn carries the tool message.
            end

            def on_keep_alive
              @out << ": keep-alive\n\n"
            end

            def on_message_delta(stop_reason:, output_tokens:)
              _ = stop_reason
              _ = output_tokens
              # Trailing fields fold into on_done.
            end

            def on_done(stop_reason:, usage:, model:)
              return if @done_emitted

              finish_reason = FINISH_REASON_MAP[stop_reason] || 'stop'
              done_chunk = {
                id:      "chatcmpl-#{@request_id.to_s.delete('-')}",
                object:  'chat.completion.chunk',
                created: Time.now.to_i,
                model:   model.to_s,
                choices: [{ index: 0, delta: {}, finish_reason: finish_reason }],
                usage:   {
                  prompt_tokens:     usage[:input_tokens].to_i,
                  completion_tokens: usage[:output_tokens].to_i,
                  total_tokens:      usage[:input_tokens].to_i + usage[:output_tokens].to_i
                }
              }
              emit_chunk(done_chunk)
              @out << "data: [DONE]\n\n"
              @done_emitted = true
            end

            def on_error(message:, type:, status_code:)
              _ = status_code
              emit_chunk({ error: { message: message, type: type } })
              @out << "data: [DONE]\n\n" unless @done_emitted
              @done_emitted = true
            end

            private

            def emit_chunk(chunk)
              @out << "data: #{Legion::JSON.dump(chunk)}\n\n"
            end

            def delta_envelope(delta, finish_reason: nil)
              {
                id:      "chatcmpl-#{@request_id.to_s.delete('-')}",
                object:  'chat.completion.chunk',
                created: Time.now.to_i,
                model:   @model,
                choices: [{ index: 0, delta: delta, finish_reason: finish_reason }]
              }
            end
          end

          private

          def chunk_envelope(delta, finish_reason: nil)
            {
              id:      "chatcmpl-#{SecureRandom.uuid.delete('-')}",
              object:  'chat.completion.chunk',
              created: Time.now.to_i,
              choices: [{ index: 0, delta: delta, finish_reason: finish_reason }]
            }
          end

          def symbolize(body)
            return {} if body.nil?
            return body.transform_keys(&:to_sym) if body.respond_to?(:transform_keys)

            body
          end

          def extract_messages_and_system(raw)
            system_content = nil
            messages = []
            raw.each do |msg|
              m = symbolize(msg)
              role = m[:role].to_sym
              case role
              when :system
                system_content = extract_content(m[:content])
              when :assistant
                entry = { role: role, content: extract_content(m[:content]) }
                entry[:tool_calls] = normalize_assistant_tool_calls(m[:tool_calls]) if m[:tool_calls]
                messages << entry
              when :tool
                messages << { role: role, content: extract_content(m[:content]), tool_call_id: m[:tool_call_id] }.compact
              else
                messages << { role: role, content: extract_content(m[:content]) }
              end
            end
            [messages, system_content]
          end

          def normalize_assistant_tool_calls(tool_calls)
            return nil unless tool_calls.is_a?(Array) && tool_calls.any?

            tool_calls.filter_map do |tc|
              tc = symbolize(tc)
              fn = symbolize(tc[:function])
              next unless fn.is_a?(Hash)

              {
                id:        tc[:id] || "call_#{fn[:name]}_#{SecureRandom.hex(8)}",
                name:      fn[:name].to_s,
                arguments: fn[:arguments].is_a?(String) ? safe_parse_args(fn[:arguments]) : (fn[:arguments] || {})
              }
            rescue StandardError => e
              handle_exception(e, level: :warn, handled: true,
                                  operation: 'llm.client_translator.openai_chat.normalize_tool_call')
              nil
            end
          end

          def extract_content(content)
            return content if content.is_a?(String)
            return content unless content.is_a?(Array)

            normalized = content.map { |b| symbolize(b) }
            has_non_text = normalized.any? { |b| b[:type].to_s != 'text' }
            return normalized if has_non_text

            normalized.filter_map { |b| b[:text] if b[:type].to_s == 'text' }.join("\n\n")
          end

          def build_tools(raw)
            return nil unless raw.is_a?(Array) && !raw.empty?

            raw.filter_map do |tool|
              t = symbolize(tool)
              if t[:type].to_s == 'function'
                fn = symbolize(t[:function])
                next unless fn.is_a?(Hash) && fn[:name].to_s.length.positive?

                { name: fn[:name].to_s, description: fn[:description].to_s, parameters: fn[:parameters] || {}, source: { type: :client, executable: true } }
              elsif t[:name].to_s.length.positive?
                { name: t[:name].to_s, description: t[:description].to_s, parameters: t[:parameters] || {}, source: { type: :client, executable: true } }
              end
            end
          end

          def extract_params(body)
            params = {
              max_tokens:        body[:max_tokens],
              temperature:       body[:temperature],
              top_p:             body[:top_p],
              top_k:             body[:top_k],
              stop_sequences:    body[:stop],
              frequency_penalty: body[:frequency_penalty],
              presence_penalty:  body[:presence_penalty],
              response_format:   body[:response_format],
              seed:              body[:seed]
            }.compact
            params.empty? ? nil : params
          end

          def extract_client_tool_passthrough(body, env)
            if env.key?('HTTP_X_LEGION_CLIENT_TOOL_PASSTHROUGH')
              env['HTTP_X_LEGION_CLIENT_TOOL_PASSTHROUGH'] == 'true'
            elsif [true, false].include?(body[:client_tool_passthrough])
              body[:client_tool_passthrough]
            end
          end

          def external_refs(body, env)
            refs = {
              http_thread_id:    env['HTTP_THREAD_ID'],
              client_request_id: env['HTTP_X_CLIENT_REQUEST_ID'],
              user_provided_id:  body[:request_id]
            }.compact
            refs.empty? ? nil : refs
          end

          def build_tool_definitions(canonical_tools)
            return [] if canonical_tools.nil? || canonical_tools.empty?

            canonical_tools.values.filter_map do |t|
              hash = t.respond_to?(:to_h) ? t.to_h : t
              next if hash[:name].to_s.empty?

              Legion::LLM::Types::ToolDefinition.build(
                name:        hash[:name].to_s,
                description: hash[:description].to_s,
                parameters:  hash[:parameters] || {},
                source:      { type: :client, executable: true }
              )
            rescue StandardError => e
              handle_exception(e, level: :warn, handled: true,
                                  operation: 'llm.client_translator.openai_chat.build_tool', tool_name: hash[:name])
              nil
            end
          end

          def inference_messages(canonical_messages)
            canonical_messages.map do |m|
              hash = m.respond_to?(:to_h) ? m.to_h : m
              {
                role:         hash[:role],
                content:      hash[:content],
                tool_calls:   hash[:tool_calls],
                tool_call_id: hash[:tool_call_id]
              }.compact
            end
          end

          # Actionable tool_calls only — server-executed (resolved) LegionIO
          # tools are filtered out per G24. The server-side exchange landed
          # in the conversation history via the executor's tool loop; the
          # chat.completions surface only carries client-callable tools.
          def build_tool_calls(pipeline_response)
            tools = pipeline_response.respond_to?(:tools) ? pipeline_response.tools : nil
            return [] unless tools.respond_to?(:any?) && tools.any?

            tools.each_with_index.filter_map do |tc, idx|
              name = tc.respond_to?(:name) ? tc.name : (tc[:name] || tc['name'])
              args = tc.respond_to?(:arguments) ? tc.arguments : (tc[:arguments] || tc['arguments'] || {})
              tc_id = tc.respond_to?(:id) ? tc.id : (tc[:id] || tc['id'] || "call_#{SecureRandom.hex(8)}")
              next if name.nil?
              next if server_tool_resolved?(tc)

              {
                id:       tc_id,
                type:     'function',
                index:    idx,
                function: {
                  name:      name.to_s,
                  arguments: args.is_a?(String) ? args : Legion::JSON.dump(args)
                }
              }
            end
          end

          def server_tool_resolved?(tool_call)
            source = if tool_call.respond_to?(:source)
                       tool_call.source
                     elsif tool_call.is_a?(Hash)
                       tool_call[:source] || tool_call['source']
                     end
            return false if source.nil?

            type = source.is_a?(Hash) ? (source[:type] || source['type']) : source
            return false unless %i[special registry extension mcp].include?(type&.to_sym)

            result = if tool_call.respond_to?(:result)
                       tool_call.result
                     elsif tool_call.is_a?(Hash)
                       tool_call[:result] || tool_call['result']
                     end
            !result.nil?
          end

          def map_finish_reason(stop_reason)
            return 'stop' if stop_reason.nil? || stop_reason.to_s.empty?

            mapping = { 'end_turn' => 'stop', 'stop' => 'stop', 'length' => 'length',
                        'max_tokens' => 'length', 'tool_use' => 'tool_calls',
                        'tool_calls' => 'tool_calls', 'content_filter' => 'content_filter',
                        'stop_sequence' => 'stop' }
            mapping.fetch(stop_reason.to_s, 'stop')
          end

          def content_looks_like_tool_json?(content)
            stripped = content.to_s.strip
            return false unless stripped.start_with?('{"') && stripped.end_with?('}')

            parsed = Legion::JSON.parse(stripped, symbolize_names: false)
            parsed.is_a?(Hash) && parsed.keys.any?
          rescue Legion::JSON::ParseError, StandardError
            false
          end

          def extract_thinking_text(value)
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

          def token_value(tokens, *keys)
            return 0 if tokens.nil?

            keys.each do |key|
              value = if tokens.is_a?(Hash)
                        tokens[key] || tokens[key.to_s]
                      elsif tokens.respond_to?(key)
                        tokens.public_send(key)
                      end
              return value.to_i unless value.nil?
            end
            0
          end

          def safe_parse_args(str)
            Legion::JSON.parse(str, symbolize_names: false)
          rescue StandardError
            str
          end
        end
      end
    end
  end
end
