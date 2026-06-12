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
        # OpenAI /v1/responses (Responses API) client translator.
        #
        # Per Phase 5:
        #   - parse_request(body, env) -> Canonical::Request (handles
        #     input/instructions/reasoning/tools shapes specific to /v1/responses)
        #   - format_response(canonical_or_pipeline_response) -> Hash with output[]
        #     containing {thinking, function_call, message} items
        #   - format_error(error, status_code:, type:)
        #   - events_emitter(out, ...) -> Events emitter conforming to the
        #     StreamAssembler contract.
        class OpenAIResponses
          extend Legion::Logging::Helper
          include Legion::Logging::Helper

          Canonical = Legion::Extensions::Llm::Canonical

          def parse_request(body, env = {})
            log.debug('[llm][client_translator][openai_responses] action=parse_request')
            body = symbolize(body)

            messages = build_messages(body[:input], body[:instructions])
            tools = build_tools(body[:tools])
            params = build_params(body)
            thinking = build_thinking(body[:reasoning])

            Canonical::Request.build(
              id:              env['HTTP_X_CLIENT_REQUEST_ID'] || "resp_#{SecureRandom.hex(16)}",
              messages:        messages,
              tools:           tools,
              params:          params,
              thinking:        thinking,
              stream:          body[:stream] == true,
              conversation_id: env['HTTP_X_LEGION_CONVERSATION_ID'] || env['HTTP_THREAD_ID'] || body[:conversation],
              routing:         { model: body[:model], provider: env['HTTP_X_LEGION_PROVIDER'], instance: env['HTTP_X_LEGION_INSTANCE'] }.compact,
              metadata:        {
                tier:          env['HTTP_X_LEGION_TIER'],
                external_refs: external_refs(body, env),
                upstream_body: body # preserved for native call_responses path until executor is canonical
              }.compact
            )
          end

          def build_inference_request(canonical_request, request_id:, server_caller:, modality: nil)
            tool_defs = build_tool_definitions(canonical_request.tools)

            extra = {}
            tier = canonical_request.metadata[:tier]
            extra[:tier] = tier.to_sym if tier

            messages = inference_messages(canonical_request.messages)

            Legion::LLM::Inference::Request.build(
              id:              request_id,
              messages:        messages,
              system:          canonical_request.system,
              routing:         canonical_request.routing,
              tools:           tool_defs,
              caller:          server_caller,
              conversation_id: canonical_request.conversation_id,
              stream:          canonical_request.stream == true,
              modality:        modality,
              thinking:        thinking_to_inference(canonical_request.thinking),
              cache:           { strategy: :default, cacheable: true },
              extra:           extra,
              metadata:        canonical_request.metadata.except(:upstream_body)
            )
          end

          def format_response(pipeline_response, model:, request_id:)
            routing = pipeline_response.respond_to?(:routing) ? pipeline_response.routing || {} : {}
            tokens = pipeline_response.respond_to?(:tokens) ? pipeline_response.tokens || {} : {}
            raw_msg = pipeline_response.respond_to?(:message) ? pipeline_response.message : nil
            content = raw_msg.is_a?(Hash) ? (raw_msg[:content] || raw_msg['content']).to_s : raw_msg.to_s
            resolved_model = (routing[:model] || routing['model'] || model).to_s

            tool_calls = build_output_tool_calls(pipeline_response)
            reasoning = build_output_reasoning(pipeline_response)

            output = [*reasoning, *tool_calls, {
              type:    'message',
              id:      "msg_#{SecureRandom.hex(12)}",
              role:    'assistant',
              content: [{ type: 'output_text', text: content }],
              status:  'completed'
            }]

            status = tool_calls.any? ? 'requires_action' : 'completed'

            result = {
              id:         request_id,
              object:     'response',
              created_at: Time.now.to_i,
              model:      resolved_model,
              output:     output,
              usage:      build_usage(tokens),
              status:     status
            }

            result[:action_required] = { type: 'function_calls', function_calls: tool_calls } if tool_calls.any?

            result
          end

          def format_error(error, status_code: 500, type: 'server_error')
            [status_code, { error: { message: error.respond_to?(:message) ? error.message : error.to_s, type: type } }]
          end

          def events_emitter(out, request_id:, model:, conv_id: nil)
            Events.new(out: out, request_id: request_id, model: model.to_s, conv_id: conv_id)
          end

          # Format a single Canonical::Chunk to a /v1/responses SSE event hash.
          def format_chunk(canonical_chunk)
            return nil if canonical_chunk.nil?

            case canonical_chunk.type
            when :text_delta
              { type: 'response.output_text.delta', delta: canonical_chunk.delta.to_s,
                output_index: canonical_chunk.block_index || 0 }
            when :thinking_delta
              { type: 'response.thinking.delta', delta: canonical_chunk.delta.to_s,
                output_index: canonical_chunk.block_index || 0 }
            when :tool_call_delta
              tc = canonical_chunk.tool_call
              args = tc.respond_to?(:arguments) ? tc.arguments : {}
              { type:         'response.function_call_arguments.delta',
                output_index: canonical_chunk.block_index || 0,
                delta:        serialize_args(args) }
            when :done
              { type: 'response.completed' }
            end
          end

          # SSE Events emitter for /v1/responses. Emits sequence_number'd events
          # following the OpenAI Responses API spec.
          class Events
            include Legion::Logging::Helper

            def initialize(out:, request_id:, model:, conv_id: nil)
              @out = out
              @request_id = request_id
              @model = model
              @conv_id = conv_id
              @seq = 0
              @output_items = []
              @msg_id = "msg_#{SecureRandom.hex(12)}"
              @msg_index = nil
              @msg_opened = false
              @full_text = +''
              @full_reasoning = +''
              @thinking_state = nil
              @pending_tool_calls = {} # block_index => { id, name, arguments_str, output_index }
              @created_at = Time.now.to_i
            end

            def on_start(model:, request_id:, input_tokens:)
              _ = input_tokens
              base = { id: request_id, object: 'response', created_at: @created_at,
                       status: 'in_progress', model: model.to_s, output: [], usage: nil }
              emit('response.created',     { type: 'response.created',     sequence_number: next_seq, response: base })
              emit('response.in_progress', { type: 'response.in_progress', sequence_number: next_seq, response: base })
            end

            def on_text_open(block_index:)
              _ = block_index
              open_message
            end

            def on_text_delta(block_index:, text:)
              _ = block_index
              close_thinking_item
              open_message
              @full_text << text
              emit('response.output_text.delta', {
                     type: 'response.output_text.delta', sequence_number: next_seq,
                     output_index: @msg_index, content_index: 0, item_id: @msg_id, delta: text
                   })
            end

            def on_text_close(block_index:)
              _ = block_index
              # Closure happens at on_done.
            end

            def on_thinking_open(block_index:)
              _ = block_index
              return if @thinking_state

              state = {
                type:     'thinking',
                id:       "thnk_#{SecureRandom.hex(12)}",
                thinking: +'',
                status:   'in_progress'
              }
              @output_items << state
              @thinking_state = state
              output_index = @output_items.length - 1
              emit('response.output_item.added', {
                     type: 'response.output_item.added', sequence_number: next_seq,
                     output_index: output_index, item: state
                   })
              emit('response.thinking_part.added', {
                     type: 'response.thinking_part.added', sequence_number: next_seq,
                     output_index: output_index, item_id: state[:id],
                     part: { type: 'thinking', thinking: '' }
                   })
            end

            def on_thinking_delta(block_index:, text:, signature:)
              _ = block_index
              _ = signature
              return if text.to_s.empty? || @thinking_state.nil?

              @full_reasoning << text
              @thinking_state[:thinking] << text
              output_index = @output_items.index(@thinking_state)
              emit('response.thinking.delta', {
                     type: 'response.thinking.delta', sequence_number: next_seq,
                     output_index: output_index, item_id: @thinking_state[:id], delta: text
                   })
            end

            def on_thinking_close(block_index:, signature:)
              _ = block_index
              _ = signature
              close_thinking_item
            end

            def on_tool_call_open(block_index:, tool_call:, server_tool:)
              _ = server_tool
              tc_id = tool_call[:id] || "call_#{SecureRandom.hex(12)}"
              idx = @output_items.length
              item = { id: tc_id, type: 'function_call', name: tool_call[:name].to_s,
                       call_id: tc_id, arguments: '', status: 'in_progress' }
              @output_items << item
              @pending_tool_calls[block_index] = {
                id:            tc_id,
                name:          tool_call[:name].to_s,
                arguments_str: '',
                output_index:  idx,
                args_emitted:  +''
              }
              emit('response.output_item.added', {
                     type: 'response.output_item.added', sequence_number: next_seq,
                     output_index: idx, item: item
                   })
            end

            def on_tool_call_delta(block_index:, partial_arguments_json:)
              state = @pending_tool_calls[block_index]
              return if state.nil?

              # If the assembler hands us a cumulative string (buffered close)
              # only emit the diff vs already emitted.
              new_part = if partial_arguments_json.start_with?(state[:args_emitted])
                           partial_arguments_json[state[:args_emitted].length..]
                         else
                           partial_arguments_json
                         end
              return if new_part.to_s.empty?

              state[:args_emitted] << new_part
              state[:arguments_str] = state[:args_emitted]
              emit('response.function_call_arguments.delta', {
                     type: 'response.function_call_arguments.delta', sequence_number: next_seq,
                     output_index: state[:output_index], item_id: state[:id], delta: new_part
                   })
            end

            def on_tool_call_close(block_index:)
              state = @pending_tool_calls[block_index]
              return if state.nil?

              emit('response.function_call_arguments.done', {
                     type: 'response.function_call_arguments.done', sequence_number: next_seq,
                     output_index: state[:output_index], item_id: state[:id],
                     arguments: state[:arguments_str]
                   })
              completed = { id: state[:id], type: 'function_call', name: state[:name],
                            call_id: state[:id], arguments: state[:arguments_str], status: 'completed' }
              emit('response.output_item.done', {
                     type: 'response.output_item.done', sequence_number: next_seq,
                     output_index: state[:output_index], item: completed
                   })
              @output_items[state[:output_index]] = completed
            end

            def on_server_tool_result(block_index:, tool_call_id:, result_text:)
              _ = block_index
              _ = tool_call_id
              _ = result_text
              # /v1/responses doesn't expose server tool results inline today —
              # the function_call output item carries id/args; result is part
              # of the assistant message that follows on the next turn.
            end

            def on_keep_alive
              # SSE comment line — keeps the connection alive without issuing
              # a typed event.
              @out << ": keep-alive\n\n"
            end

            def on_message_delta(stop_reason:, output_tokens:)
              _ = stop_reason
              _ = output_tokens
              # Consolidated trailer happens in on_done.
            end

            def on_done(stop_reason:, usage:, model:)
              close_thinking_item

              if @msg_opened
                emit('response.output_text.done', {
                       type: 'response.output_text.done', sequence_number: next_seq,
                       output_index: @msg_index, content_index: 0, item_id: @msg_id, text: @full_text
                     })
                emit('response.content_part.done', {
                       type: 'response.content_part.done', sequence_number: next_seq,
                       output_index: @msg_index, content_index: 0, item_id: @msg_id,
                       part: { type: 'output_text', text: @full_text, annotations: [] }
                     })
                completed_item = { id: @msg_id, type: 'message', role: 'assistant', status: 'completed',
                                   content: [{ type: 'output_text', text: @full_text, annotations: [] }] }
                emit('response.output_item.done', {
                       type: 'response.output_item.done', sequence_number: next_seq,
                       output_index: @msg_index, item: completed_item
                     })
                @output_items[@msg_index] = completed_item
              end

              has_tool_calls = @pending_tool_calls.any?
              status = stop_reason == :tool_use || has_tool_calls ? 'requires_action' : 'completed'
              event = status == 'requires_action' ? 'response.done' : 'response.completed'
              payload = {
                type: event, sequence_number: next_seq,
                response: {
                  id: @request_id, object: 'response', created_at: @created_at,
                  status: status, model: model.to_s,
                  output: @output_items, usage: format_usage(usage)
                }
              }
              if status == 'requires_action'
                payload[:response][:action_required] = {
                  type:           'function_calls',
                  function_calls: @output_items.select { |i| i[:type] == 'function_call' }
                }
              end
              emit(event, payload)
            end

            def on_error(message:, type:, status_code:)
              _ = status_code
              emit('error', { type: 'error', message: message, code: type })
            end

            private

            def emit(event_name, payload)
              @out << "event: #{event_name}\ndata: #{Legion::JSON.dump(payload)}\n\n"
            end

            def next_seq
              @seq += 1
            end

            def open_message
              return if @msg_opened

              @msg_index = @output_items.length
              message_item = { id: @msg_id, type: 'message', role: 'assistant', content: [], status: 'in_progress' }
              @output_items << message_item
              emit('response.output_item.added', {
                     type: 'response.output_item.added', sequence_number: next_seq,
                     output_index: @msg_index, item: message_item
                   })
              emit('response.content_part.added', {
                     type: 'response.content_part.added', sequence_number: next_seq,
                     output_index: @msg_index, content_index: 0, item_id: @msg_id,
                     part: { type: 'output_text', text: '', annotations: [] }
                   })
              @msg_opened = true
            end

            def close_thinking_item
              return unless @thinking_state && @thinking_state[:status] == 'in_progress'

              output_index = @output_items.index(@thinking_state)
              @thinking_state[:status] = 'completed'
              text = @thinking_state[:thinking].to_s
              emit('response.thinking.done', {
                     type: 'response.thinking.done', sequence_number: next_seq,
                     output_index: output_index, item_id: @thinking_state[:id], text: text
                   })
              emit('response.thinking_part.done', {
                     type: 'response.thinking_part.done', sequence_number: next_seq,
                     output_index: output_index, item_id: @thinking_state[:id],
                     part: { type: 'thinking', thinking: text }
                   })
              emit('response.output_item.done', {
                     type: 'response.output_item.done', sequence_number: next_seq,
                     output_index: output_index, item: @thinking_state
                   })
              @thinking_state = nil
            end

            def format_usage(usage)
              return { input_tokens: 0, output_tokens: 0, total_tokens: 0 } if usage.nil?

              i = usage[:input_tokens].to_i
              o = usage[:output_tokens].to_i
              { input_tokens: i, output_tokens: o, total_tokens: i + o }
            end
          end

          private

          def symbolize(body)
            return {} if body.nil?
            return body.transform_keys(&:to_sym) if body.respond_to?(:transform_keys)

            body
          end

          def build_messages(input, instructions)
            messages = case input
                       when Array
                         normalize_input_array(input)
                       when String
                         [{ role: 'user', content: input }]
                       else
                         []
                       end
            messages = [{ role: 'system', content: instructions.to_s }] + messages if instructions

            messages.map do |m|
              {
                role:         m[:role] || m['role'],
                content:      m[:content] || m['content'],
                tool_calls:   m[:tool_calls] || m['tool_calls'],
                tool_call_id: m[:tool_call_id] || m['tool_call_id']
              }.compact
            end
          end

          def normalize_input_array(input)
            messages = []
            pending_tool_calls = []

            input.each do |item|
              item = symbolize(item)
              case item[:type].to_s
              when 'function_call'
                pending_tool_calls << {
                  id:        item[:call_id] || item[:id],
                  name:      item[:name].to_s,
                  arguments: item[:arguments].is_a?(String) ? item[:arguments] : Legion::JSON.dump(item[:arguments] || {})
                }
              when 'function_call_output'
                flush_pending_tool_calls(messages, pending_tool_calls)
                messages << { role: 'tool', tool_call_id: item[:call_id], content: item[:output].to_s }
              else
                flush_pending_tool_calls(messages, pending_tool_calls)
                role = item[:role]&.to_s
                next unless role

                role = 'system' if role == 'developer'

                content = item[:content]
                content = content.to_s if content && !content.is_a?(Array)
                messages << { role: role, content: content }.compact
              end
            end
            flush_pending_tool_calls(messages, pending_tool_calls)
            messages
          end

          # Emit FLAT tool_call hashes ({id, name, arguments}) — Canonical::Message.from_hash
          # forwards each tool_call hash to ToolCall.from_hash, which expects
          # name and arguments at the top level. The OpenAI nested
          # {type: 'function', function: {name, arguments}} envelope produces
          # ToolCall(name: nil) — provider translators then drop the call,
          # leaving an orphan tool_result that Bedrock rejects with
          # "unexpected tool_use_id in tool_result".
          def flush_pending_tool_calls(messages, pending)
            return if pending.empty?

            messages << {
              role:       'assistant',
              content:    '',
              tool_calls: pending.map do |tc|
                args = tc[:arguments]
                args = safe_parse_json(args) if args.is_a?(String)
                { id: tc[:id], name: tc[:name].to_s, arguments: args || {} }
              end
            }
            pending.clear
          end

          def safe_parse_json(str)
            return {} if str.to_s.empty?

            Legion::JSON.load(str)
          rescue StandardError
            str
          end

          def build_tools(raw_tools)
            return nil unless raw_tools.is_a?(Array) && !raw_tools.empty?

            raw_tools.filter_map do |tool|
              t = symbolize(tool)
              fn = t[:function] || t
              fn = symbolize(fn)
              next if fn[:name].to_s.empty?

              {
                name:        fn[:name].to_s,
                description: fn[:description].to_s,
                parameters:  fn[:parameters] || {},
                source:      { type: :client, executable: true }
              }
            end
          end

          def build_params(body)
            params = {
              max_tokens:        body[:max_output_tokens] || body[:max_tokens],
              temperature:       body[:temperature],
              top_p:             body[:top_p],
              frequency_penalty: body[:frequency_penalty],
              presence_penalty:  body[:presence_penalty]
            }.compact
            params.empty? ? nil : params
          end

          # /v1/responses uses `reasoning: { effort: low|medium|high }`.
          # Canonical::ThinkingConfig accepts {effort:, budget:} — anything
          # else raises ArgumentError downstream. The Anthropic-budget mapping
          # for cross-provider routing lives in the provider translator
          # (lex-llm-anthropic) where the budget translates to budget_tokens.
          def build_thinking(reasoning)
            return nil if reasoning.nil?

            effort = if reasoning.is_a?(Hash)
                       reasoning[:effort] || reasoning['effort']
                     else
                       reasoning
                     end

            case effort.to_s
            when 'low'
              { effort: effort.to_s, budget: 512 }
            when 'medium', 'high'
              { effort: effort.to_s, budget: 1024 }
            end
          end

          # Canonical::ThinkingConfig#to_h is {effort:, budget:}. Downstream
          # providers (anthropic native + lex-llm-openai responses) expect the
          # {type: 'enabled', budget_tokens:, effort:} shape originally
          # produced by extract_thinking_config in the legacy route.
          def thinking_to_inference(thinking)
            return nil if thinking.nil?

            h = thinking.respond_to?(:to_h) ? thinking.to_h : thinking
            return nil unless h.is_a?(Hash) && !h.empty?

            inference = { type: 'enabled' }
            inference[:budget_tokens] = h[:budget] if h[:budget]
            inference[:effort] = h[:effort] if h[:effort]
            inference
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
                                  operation: 'llm.client_translator.openai_responses.build_tool', tool_name: hash[:name])
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

          def external_refs(body, env)
            refs = {
              http_thread_id:    env['HTTP_THREAD_ID'],
              client_request_id: env['HTTP_X_CLIENT_REQUEST_ID'],
              codex_session_id:  env['HTTP_X_CODEX_SESSION_ID'],
              previous_response: body[:previous_response_id]
            }.compact
            refs.empty? ? nil : refs
          end

          def build_output_tool_calls(pipeline_response)
            tools = pipeline_response.respond_to?(:tools) ? pipeline_response.tools : nil
            return [] unless tools.respond_to?(:any?) && tools.any?

            tools.filter_map do |tc|
              name = tc.respond_to?(:name) ? tc.name : (tc[:name] || tc['name'])
              args = tc.respond_to?(:arguments) ? tc.arguments : (tc[:arguments] || tc['arguments'] || {})
              tc_id = tc.respond_to?(:id) ? tc.id : (tc[:id] || tc['id'] || "call_#{SecureRandom.hex(8)}")
              next if name.nil?

              { type: 'function_call', id: "fc_#{SecureRandom.hex(12)}", call_id: tc_id,
                name: name.to_s, arguments: args.is_a?(String) ? args : Legion::JSON.dump(args), status: 'completed' }
            end
          end

          # Surface provider thinking as a Responses-API reasoning item. Codex
          # (and the legionio-e2e reasoning gate) consume reasoning as a
          # `message` output item tagged `phase: "reasoning"` whose content
          # carries `output_text` blocks — NOT a `type: "thinking"` item, which
          # the client silently drops. Keep both shapes' text identical so the
          # canonical debug surface and the client surface agree.
          def build_output_reasoning(pipeline_response)
            thinking = pipeline_response.respond_to?(:thinking) ? pipeline_response.thinking : nil
            text = extract_thinking_text(thinking)
            return [] if text.empty?

            [{
              type:    'message',
              id:      "msg_#{SecureRandom.hex(12)}",
              role:    'assistant',
              phase:   'reasoning',
              content: [{ type: 'output_text', text: text }],
              status:  'completed'
            }]
          end

          def extract_thinking_text(value)
            return '' if value.nil?
            return value.to_s if value.is_a?(String)

            if value.is_a?(Hash)
              normalized = value.transform_keys { |k| k.respond_to?(:to_sym) ? k.to_sym : k }
              text = normalized[:content] || normalized[:text] || normalized[:thinking] || normalized[:reasoning]
              return text.to_s if text
            end

            return value.content.to_s if value.respond_to?(:content) && value.content
            return value.text.to_s if value.respond_to?(:text) && value.text

            value.to_s
          end

          def build_usage(tokens)
            i = token_value(tokens, :input_tokens, :input).to_i
            o = token_value(tokens, :output_tokens, :output).to_i
            result = { input_tokens: i, output_tokens: o, total_tokens: i + o }
            details = tokens[:output_tokens_details] || tokens['output_tokens_details']
            result[:output_tokens_details] = details if details.is_a?(Hash) && !details.empty?
            result
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

          def serialize_args(args)
            return args.to_s if args.is_a?(String)

            Legion::JSON.dump(args || {})
          rescue StandardError
            args.to_s
          end
        end
      end
    end
  end
end
