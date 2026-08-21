# frozen_string_literal: true

require 'securerandom'
require 'time'
require 'legion/logging/helper'
require 'legion/extensions/llm'
require 'legion/llm/types'
require 'legion/llm/inference/request'
require 'legion/llm/api/client_translators/shared_extractors'

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
          include SharedExtractors

          Canonical = Legion::Extensions::Llm::Canonical

          # G24 — declares which execution-proxy contract shape this translator
          # surfaces. Consumed by the lex-llm conformance shared examples.
          def g24_format
            :openai_responses
          end

          def parse_request(body, env = {})
            log.debug('[llm][client_translator][openai_responses] action=parse_request')
            body = symbolize(body)

            system, messages = build_system_and_messages(body[:input], body[:instructions])
            tools = build_tools(body[:tools])
            params = build_params(body)
            thinking = build_thinking(body[:reasoning])
            tool_choice = build_tool_choice(body[:tool_choice])

            Canonical::Request.build(
              id:              env['HTTP_X_CLIENT_REQUEST_ID'] || "resp_#{SecureRandom.hex(16)}",
              system:          system,
              messages:        messages,
              tools:           tools,
              tool_choice:     tool_choice,
              params:          params,
              thinking:        thinking,
              stream:          body[:stream] == true,
              conversation_id: env['HTTP_X_LEGION_CONVERSATION_ID'] || env['HTTP_THREAD_ID'] || body[:conversation],
              routing:         legion_routing_from_env(env),
              metadata:        {
                client_model:     body[:model],
                tier:             env['HTTP_X_LEGION_TIER'],
                routing_explicit: legion_routing_explicit_from_env(env),
                external_refs:    external_refs(body, env)
              }.compact
            )
          end

          # When the caller asks for reasoning (`reasoning.effort` set) but
          # didn't pin a summary mode, default to `summary: 'auto'`. OpenAI's
          # /v1/responses lane omits reasoning summary content unless the
          # request opts in — without this, codex→openai cells return only
          # the message item (no reasoning), and the e2e validator
          # reports "reasoning never produced" (P5-final-cells.md B3).
          def ensure_reasoning_summary(body)
            reasoning = body[:reasoning]
            return body unless reasoning.is_a?(Hash)

            normalized = reasoning.transform_keys { |k| k.respond_to?(:to_sym) ? k.to_sym : k }
            return body.merge(reasoning: normalized) if normalized.key?(:summary)
            return body unless normalized[:effort]

            body.merge(reasoning: normalized.merge(summary: 'auto'))
          end

          def build_inference_request(canonical_request, request_id:, server_caller:, modality: nil)
            tool_defs = build_tool_definitions(canonical_request.tools)

            extra = {}
            tier = canonical_request.metadata[:tier]
            extra[:tier] = tier.to_sym if tier
            routing_explicit = canonical_request.metadata[:routing_explicit]
            extra[:routing_explicit] = routing_explicit if routing_explicit

            # N x N law: the executor receives canonical messages end-to-end.
            messages = canonical_request.messages
            request_kwargs = {
              id:              request_id,
              messages:        messages,
              system:          canonical_request.system,
              routing:         canonical_request.routing,
              # Body-model routing hint (SSOT v3 D19): the sole input to
              # BodyModelHintPolicy. The trusted X-Legion-Model pin in
              # `routing` supersedes it — RequestRequirements keeps that order.
              client_model:    canonical_request.metadata[:client_model],
              tools:           tool_defs,
              tool_choice:     canonical_request.tool_choice,
              caller:          server_caller,
              conversation_id: canonical_request.conversation_id,
              stream:          canonical_request.stream == true,
              modality:        modality,
              thinking:        thinking_to_inference(canonical_request.thinking),
              cache:           { strategy: :default, cacheable: true },
              extra:           extra,
              metadata:        canonical_request.metadata
            }

            apply_canonical_params_to_inference(request_kwargs, canonical_request.params)

            Legion::LLM::Inference::Request.build(**request_kwargs)
          end

          # OpenAI Responses tool_choice shapes:
          #   "auto" / "none" / "required"          → corresponding sym
          #   {type: 'function', name: 'X'}         → {type: 'function', name: 'X'}
          #   {type: 'function', function: {name:}} → flatten to {type: 'function', name: 'X'}
          def build_tool_choice(raw)
            return nil if raw.nil?

            case raw
            when Hash
              symbolized = raw.transform_keys(&:to_sym)
              type = symbolized[:type].to_s
              if type == 'function'
                fn = symbolized[:function].is_a?(Hash) ? symbolized[:function].transform_keys(&:to_sym) : nil
                name = symbolized[:name] || fn&.[](:name)
                return { type: :function, name: name.to_s } if name

                symbolized
              else
                %w[auto none required any].include?(type) ? type.to_sym : symbolized
              end
            when String, Symbol
              raw.to_sym
            end
          end

          def format_response(pipeline_response, model:, request_id:)
            routing = pipeline_response.respond_to?(:routing) ? pipeline_response.routing || {} : {}
            tokens = pipeline_response.respond_to?(:tokens) ? pipeline_response.tokens || {} : {}
            raw_msg = pipeline_response.respond_to?(:message) ? pipeline_response.message : nil
            content = extract_content_text(raw_msg)
            resolved_model = (routing[:model] || routing['model'] || model).to_s

            actionable_tool_calls = build_output_tool_calls(pipeline_response)
            server_tool_items = build_output_server_tool_items(pipeline_response)
            reasoning = build_output_reasoning(pipeline_response)

            output = [*reasoning, *server_tool_items, *actionable_tool_calls]
            unless content.to_s.strip.empty? && (actionable_tool_calls.any? || server_tool_items.any?)
              output << {
                type:    'message',
                id:      "msg_#{SecureRandom.hex(12)}",
                role:    'assistant',
                content: [{ type: 'output_text', text: content }],
                status:  'completed'
              }
            end

            # Responses protocol: a turn is always status `completed`. Both
            # client-callable calls (actionable_tool_calls) and LegionIO-run
            # results ride in output[] — client-callable ones as function_call
            # items the client executes and continues via function_call_output.
            # requires_action / action_required are Assistants API concepts that
            # real Responses clients (Codex) reject.
            {
              id:         request_id,
              object:     'response',
              created_at: Time.now.to_i,
              model:      resolved_model,
              output:     output,
              usage:      build_usage(tokens),
              status:     'completed'
            }
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
              { type: 'response.output_text.delta', delta: extract_content_text(canonical_chunk.delta),
                output_index: canonical_chunk.block_index || 0 }
            when :thinking_delta
              { type: 'response.thinking.delta', delta: canonical_chunk.delta.to_s,
                output_index: canonical_chunk.block_index || 0 }
            when :tool_call_delta
              format_tool_call_delta_chunk(canonical_chunk)
            when :done
              { type: 'response.completed' }
            end
          end

          # G24 — server-executed tool chunks surface as completed
          # function_call output items so the client sees the call name AND
          # result inline. Plain client-callable chunks remain plain
          # function_call_arguments.delta events.
          def format_tool_call_delta_chunk(canonical_chunk)
            tc = canonical_chunk.tool_call
            args = tool_fragment_field(tc, :arguments) || {}
            output_index = canonical_chunk.block_index || 0

            if server_tool_chunk?(tc)
              {
                type:         'response.output_item.done',
                output_index: output_index,
                item:         {
                  type:      'function_call',
                  id:        "fc_#{SecureRandom.hex(12)}",
                  call_id:   tool_fragment_field(tc, :id),
                  name:      tool_fragment_field(tc, :name).to_s,
                  arguments: args_as_json_string(args),
                  status:    'completed'
                }
              }
            else
              { type:         'response.function_call_arguments.delta',
                output_index: output_index,
                delta:        args_as_json_string(args) }
            end
          end

          def server_tool_chunk?(tool_call)
            source = tool_fragment_field(tool_call, :source)
            return false if source.nil?

            type = source.is_a?(Hash) ? (source[:type] || source['type']) : source
            %i[special registry extension mcp].include?(type&.to_sym)
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

            def on_tool_call_abort(**)
              nil
            end

            def on_server_tool_result(block_index:, tool_call_id:, result_text:)
              _ = block_index
              idx = @output_items.length
              item = { id: "fco_#{tool_call_id}", type: 'function_call_output',
                       call_id: tool_call_id, output: result_text.to_s, status: 'completed' }
              @output_items << item
              emit('response.output_item.added', {
                     type: 'response.output_item.added', sequence_number: next_seq,
                     output_index: idx, item: item
                   })
              emit('response.output_item.done', {
                     type: 'response.output_item.done', sequence_number: next_seq,
                     output_index: idx, item: item
                   })
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

              # Responses protocol: every turn terminates with response.completed
              # (status completed). Client-callable function_call items ride in
              # output[]; the client executes them and continues via
              # function_call_output. requires_action / response.done are Assistants
              # API concepts that real Responses clients (Codex) reject — emitting
              # them closes the stream "before response.completed".
              _ = stop_reason
              emit('response.completed', {
                     type: 'response.completed', sequence_number: next_seq,
                     response: {
                       id: @request_id, object: 'response', created_at: @created_at,
                       status: 'completed', model: model.to_s,
                       output: @output_items, usage: format_usage(usage)
                     }
                   })
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

          # SSOT: system content belongs in the canonical `system:` field (as the
          # Anthropic translator does), NOT as a role:system message. Extract it
          # from top-level `instructions` and from any inline system/developer
          # input items, and return [system_string_or_nil, non_system_messages].
          def build_system_and_messages(input, instructions)
            raw = case input
                  when Array  then normalize_input_array(input)
                  when String then [{ role: 'user', content: input }]
                  else             []
                  end

            system_parts = []
            system_parts << instructions.to_s if instructions
            messages = []
            raw.each do |m|
              role = (m[:role] || m['role']).to_s
              if role == 'system'
                system_parts << (m[:content] || m['content']).to_s
              else
                messages << m
              end
            end

            normalized = messages.map do |m|
              {
                role:         m[:role] || m['role'],
                content:      m[:content] || m['content'],
                tool_calls:   m[:tool_calls] || m['tool_calls'],
                tool_call_id: m[:tool_call_id] || m['tool_call_id']
              }.compact
            end

            system = system_parts.reject(&:empty?).join("\n\n")
            [system.empty? ? nil : system, normalized]
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
                role = item[:role]&.to_s

                # SSOT: an assistant `message` item that arrives while tool calls
                # are still pending is the SAME assistant turn as those calls
                # (Codex/Responses orders: function_call(s) → assistant message →
                # function_call_output(s)). Merge the text as the assistant
                # message's content and flush ONE combined assistant message
                # (content + tool_calls), so the tool results that follow stay
                # adjacent to their tool_calls. Emitting a separate assistant text
                # message here splits one turn into two and wedges narration
                # between a tool_call and its result — a malformed chat/completions
                # history that makes thinking-enabled models narrate instead of
                # calling the next tool (the "dead stop").
                if role == 'assistant' && !pending_tool_calls.empty?
                  content = canonicalize_content_parts(item[:content])
                  content = content.to_s if content && !content.is_a?(Array)
                  flush_pending_tool_calls(messages, pending_tool_calls, assistant_content: content)
                  next
                end

                flush_pending_tool_calls(messages, pending_tool_calls)
                next unless role

                role = 'system' if role == 'developer'

                content = canonicalize_content_parts(item[:content])
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
          def flush_pending_tool_calls(messages, pending, assistant_content: nil)
            if pending.empty?
              # No pending calls but an assistant text turn wants flushing — emit it
              # so a trailing/standalone assistant message is never dropped.
              messages << { role: 'assistant', content: assistant_content } if assistant_content
              return
            end

            tool_calls = pending.map do |tc|
              args = tc[:arguments]
              args = safe_parse_json(args) if args.is_a?(String)
              { id: tc[:id], name: tc[:name].to_s, arguments: args || {} }
            end

            # SSOT: an assistant text item immediately followed by function_call(s)
            # is ONE assistant turn (text + tool_calls), matching the Anthropic
            # translator's single-message shape. Merge into the trailing assistant
            # text message rather than emitting a separate empty-content message.
            last = messages.last
            if last && last[:role] == 'assistant' && !last.key?(:tool_calls)
              last[:tool_calls] = tool_calls
              # Text arriving AFTER the calls (Codex order) belongs to this same turn.
              last[:content] = assistant_content if assistant_content && last[:content].to_s.empty?
            else
              # assistant_content carries text that arrived AFTER the calls in the
              # same turn — keep it ON the tool_calls message so the turn stays one
              # message and the following tool results remain adjacent.
              messages << { role: 'assistant', content: assistant_content.to_s, tool_calls: tool_calls }
            end
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
              # Canonical member keys only — the Responses dialect spelling
              # (max_output_tokens) is translated at this edge (03 O03a).
              max_tokens:        param_spelling(body, :max_tokens),
              temperature:       body[:temperature],
              top_p:             body[:top_p],
              frequency_penalty: body[:frequency_penalty],
              presence_penalty:  body[:presence_penalty]
            }.compact
            params.empty? ? nil : params
          end

          # /v1/responses uses `reasoning: { effort: low|medium|high }`.
          # Canonical::Thinking::Config accepts {effort:, budget:} — anything
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

          # Canonical::Thinking::Config#to_h is {effort:, budget:}. Downstream
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

          def external_refs(body, env)
            refs = {
              http_thread_id:    env['HTTP_THREAD_ID'],
              client_request_id: env['HTTP_X_CLIENT_REQUEST_ID'],
              codex_session_id:  env['HTTP_X_CODEX_SESSION_ID'],
              previous_response: body[:previous_response_id]
            }.compact
            refs.empty? ? nil : refs
          end

          # Actionable tool calls — emitted with status 'in_progress' so the
          # client knows it must execute and post the result back. Server-
          # executed (resolved) LegionIO tools are filtered out here; they
          # surface as completed non-actionable items via
          # build_output_server_tool_items below (G24).
          def build_output_tool_calls(pipeline_response)
            tools = pipeline_response.respond_to?(:tools) ? pipeline_response.tools : nil
            return [] unless tools.respond_to?(:any?) && tools.any?

            tools.filter_map do |tc|
              name = tc.respond_to?(:name) ? tc.name : (tc[:name] || tc['name'])
              args = tc.respond_to?(:arguments) ? tc.arguments : (tc[:arguments] || tc['arguments'] || {})
              tc_id = tc.respond_to?(:id) ? tc.id : (tc[:id] || tc['id'] || "call_#{SecureRandom.hex(8)}")
              next if name.nil?
              next if server_tool_resolved?(tc)

              { type: 'function_call', id: "fc_#{SecureRandom.hex(12)}", call_id: tc_id,
                name: name.to_s, arguments: args_as_json_string(args), status: 'completed' }
            end
          end

          # G24 — emit completed function_call + function_call_output items
          # for every resolved server-side tool. The model must see the call
          # happened AND the client must NOT re-execute, so we pair a
          # `status: 'completed'` function_call with a `function_call_output`
          # carrying the tool result — the same shape Codex sends back on the
          # next turn, so the surface is round-trippable through
          # parse_request without invention.
          def build_output_server_tool_items(pipeline_response)
            tools = pipeline_response.respond_to?(:tools) ? pipeline_response.tools : nil
            return [] unless tools.respond_to?(:any?) && tools.any?

            tools.flat_map do |tc|
              next [] unless server_tool_resolved?(tc)

              name = tc.respond_to?(:name) ? tc.name : (tc[:name] || tc['name'])
              args = tc.respond_to?(:arguments) ? tc.arguments : (tc[:arguments] || tc['arguments'] || {})
              tc_id = tc.respond_to?(:id) ? tc.id : (tc[:id] || tc['id'] || "call_#{SecureRandom.hex(8)}")
              result = tc.respond_to?(:result) ? tc.result : (tc[:result] || tc['result'])

              [
                {
                  type:      'function_call',
                  id:        "fc_#{SecureRandom.hex(12)}",
                  call_id:   tc_id,
                  name:      name.to_s,
                  arguments: args_as_json_string(args),
                  status:    'completed'
                },
                {
                  type:    'function_call_output',
                  call_id: tc_id,
                  output:  serialize_server_tool_result(result),
                  status:  'completed'
                }
              ]
            end
          end

          def serialize_server_tool_result(result)
            return '' if result.nil?
            return result if result.is_a?(String)

            Legion::JSON.dump(result)
          rescue StandardError
            result.to_s
          end

          def server_tool_resolved?(tool_call)
            source = read_tool_call_field(tool_call, :source)
            return false if source.nil?

            type = source.is_a?(Hash) ? (source[:type] || source['type']) : source
            return false unless %i[special registry extension mcp].include?(type&.to_sym)

            !read_tool_call_field(tool_call, :result).nil?
          end

          def read_tool_call_field(tool_call, field)
            return tool_call.public_send(field) if tool_call.respond_to?(field)
            return tool_call[field] if tool_call.is_a?(Hash)

            nil
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

          def build_usage(tokens)
            i = token_value(tokens, :input_tokens, :input).to_i
            o = token_value(tokens, :output_tokens, :output).to_i
            result = { input_tokens: i, output_tokens: o, total_tokens: i + o }
            # Dual-shape: legacy Types::Usage carries the member; a Hash may
            # carry either key; Canonical::Usage has no such member (nil).
            details = if tokens.is_a?(Hash)
                        tokens[:output_tokens_details] || tokens['output_tokens_details']
                      elsif tokens.respond_to?(:output_tokens_details)
                        tokens.output_tokens_details
                      end
            result[:output_tokens_details] = details if details.is_a?(Hash) && !details.empty?
            result
          end
        end
      end
    end
  end
end
