# frozen_string_literal: true

require 'securerandom'
require 'legion/logging/helper'
require 'legion/extensions/llm'
require 'legion/llm/types'
require 'legion/llm/inference/request'
require 'legion/llm/api/client_translators/shared_extractors'

module Legion
  module LLM
    module API
      module ClientTranslators
        # Anthropic /v1/messages client translator.
        #
        # Per Phase 5 (P5):
        #   - parse_request(body, env) -> Canonical::Request
        #   - format_response(canonical) -> Hash (Anthropic Messages shape)
        #   - format_error(error, status_code:, type:) -> Hash
        #   - events_emitter(out, request_id:, model:, conv_id:) -> Events
        #     emitter for StreamAssembler (Anthropic SSE event names).
        #
        # Absorbs the logic of api/translators/anthropic_request.rb and
        # api/translators/anthropic_response.rb (now deleted in P6).
        class AnthropicMessages
          extend Legion::Logging::Helper
          include Legion::Logging::Helper
          include SharedExtractors

          Canonical = Legion::Extensions::Llm::Canonical

          STOP_REASON_MAP = {
            end_turn:       'end_turn',
            tool_use:       'tool_use',
            max_tokens:     'max_tokens',
            stop_sequence:  'stop_sequence',
            content_filter: 'content_filter',
            error:          'end_turn',
            pause_turn:     'pause_turn'
          }.freeze

          # G24 — declares which execution-proxy contract shape this translator
          # surfaces. Consumed by the lex-llm conformance shared examples.
          def g24_format
            :claude_messages
          end

          # Parse an Anthropic Messages API body + Rack env into a
          # Canonical::Request. R9: conversation_id is the Legion-internal id;
          # external refs (HTTP_THREAD_ID, claude session ids, body
          # conversation_id) are persisted in metadata[:external_refs].
          def parse_request(body, env = {})
            log.debug('[llm][client_translator][anthropic] action=parse_request')
            body = symbolize(body)

            messages = extract_messages(body[:messages] || [])
            system = extract_system(body[:system])
            tools = extract_tools(body[:tools])
            params = extract_params(body)
            thinking = extract_thinking(body[:thinking])
            tool_choice = extract_tool_choice(body[:tool_choice])
            external_refs = extract_external_refs(body, env)

            Canonical::Request.build(
              id:              env['HTTP_X_CLIENT_REQUEST_ID'] || "msg_#{SecureRandom.hex(12)}",
              messages:        messages,
              system:          system,
              tools:           tools,
              tool_choice:     tool_choice,
              params:          params,
              thinking:        thinking,
              stream:          body[:stream] == true,
              conversation_id: resolve_conversation_id(body, env),
              caller:          nil,
              routing:         { model: body[:model], provider: env['HTTP_X_LEGION_PROVIDER'], instance: env['HTTP_X_LEGION_INSTANCE'] }.compact,
              metadata:        {
                anthropic_version: body[:anthropic_version],
                tier:              env['HTTP_X_LEGION_TIER'],
                external_refs:     external_refs
              }.compact
            )
          end

          # Build an Inference::Request from a parsed Canonical::Request +
          # the raw env (the executor still consumes Inference::Request as of
          # P4a; this is the Phase-5 bridge).
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
              tool_choice:     canonical_request.tool_choice,
              caller:          server_caller,
              conversation_id: canonical_request.conversation_id,
              stream:          canonical_request.stream == true,
              modality:        modality,
              thinking:        thinking_to_inference(canonical_request.thinking),
              cache:           { strategy: :default, cacheable: true },
              extra:           extra,
              metadata:        canonical_request.metadata
            )
          end

          # Anthropic tool_choice shapes:
          #   {type: 'auto'}            → :auto
          #   {type: 'any'}             → :any (force-some-tool)
          #   {type: 'tool', name: 'X'} → {type: 'tool', name: 'X'}
          #   {type: 'none'}            → :none
          def extract_tool_choice(raw)
            return nil if raw.nil?

            case raw
            when Hash
              symbolized = raw.transform_keys(&:to_sym)
              type = symbolized[:type].to_s
              return symbolized if type == 'tool' && symbolized[:name]

              %w[auto any none required].include?(type) ? type.to_sym : symbolized
            when String, Symbol
              raw.to_sym
            end
          end

          # Non-streaming response formatting — pipeline_response is an
          # Inference::Response (the executor's envelope; carries the
          # provider-boundary canonical shape inside).
          def format_response(pipeline_response, model:, request_id:)
            content = build_content(pipeline_response)
            tokens = pipeline_response.respond_to?(:tokens) ? pipeline_response.tokens : nil
            routing = pipeline_response.respond_to?(:routing) ? pipeline_response.routing || {} : {}
            resolved_model = (routing[:model] || routing['model'] || model).to_s

            {
              id:            request_id,
              type:          'message',
              role:          'assistant',
              content:       content,
              model:         resolved_model,
              stop_reason:   format_stop_reason(pipeline_response),
              stop_sequence: nil,
              usage:         {
                input_tokens:  token_value(tokens, :input, :input_tokens) || 0,
                output_tokens: token_value(tokens, :output, :output_tokens) || 0
              }
            }
          end

          def format_error(error, status_code: 500, type: 'api_error')
            [status_code, { type: 'error', error: { type: type, message: error.respond_to?(:message) ? error.message : error.to_s } }]
          end

          # Emitter implementing the StreamAssembler emitter contract for the
          # Anthropic SSE format (event: name + data: payload).
          def events_emitter(out, request_id:, model:, conv_id: nil)
            Events.new(out: out, request_id: request_id, model: model.to_s, conv_id: conv_id)
          end

          # SSE emitter for Anthropic Messages API.
          class Events
            include Legion::Logging::Helper

            attr_reader :request_id

            def initialize(out:, request_id:, model:, conv_id: nil)
              @out = out
              @request_id = request_id
              @model = model
              @conv_id = conv_id
            end

            def on_start(model:, request_id:, input_tokens:)
              emit('message_start', {
                     type:    'message_start',
                     message: {
                       id:            request_id,
                       type:          'message',
                       role:          'assistant',
                       content:       [],
                       model:         model.to_s,
                       stop_reason:   nil,
                       stop_sequence: nil,
                       usage:         { input_tokens: input_tokens.to_i, output_tokens: 0 }
                     }
                   })
            end

            def on_text_open(block_index:)
              emit('content_block_start', {
                     type:          'content_block_start',
                     index:         block_index,
                     content_block: { type: 'text', text: '' }
                   })
              emit('ping', { type: 'ping' })
            end

            def on_text_delta(block_index:, text:)
              emit('content_block_delta', {
                     type:  'content_block_delta',
                     index: block_index,
                     delta: { type: 'text_delta', text: text }
                   })
            end

            def on_text_close(block_index:)
              emit('content_block_stop', { type: 'content_block_stop', index: block_index })
            end

            def on_thinking_open(block_index:)
              emit('content_block_start', {
                     type:          'content_block_start',
                     index:         block_index,
                     content_block: { type: 'thinking', thinking: '', signature: '' }
                   })
            end

            def on_thinking_delta(block_index:, text:, signature:)
              unless text.to_s.empty?
                emit('content_block_delta', {
                       type:  'content_block_delta',
                       index: block_index,
                       delta: { type: 'thinking_delta', thinking: text }
                     })
              end
              return if signature.to_s.empty?

              emit('content_block_delta', {
                     type:  'content_block_delta',
                     index: block_index,
                     delta: { type: 'signature_delta', signature: signature }
                   })
            end

            def on_thinking_close(block_index:, signature:)
              unless signature.to_s.empty?
                emit('content_block_delta', {
                       type:  'content_block_delta',
                       index: block_index,
                       delta: { type: 'signature_delta', signature: signature }
                     })
              end
              emit('content_block_stop', { type: 'content_block_stop', index: block_index })
            end

            def on_tool_call_open(block_index:, tool_call:, server_tool:)
              emit('content_block_start', {
                     type:          'content_block_start',
                     index:         block_index,
                     content_block: {
                       type:  server_tool ? 'server_tool_use' : 'tool_use',
                       id:    tool_call[:id] || (server_tool ? "srvtoolu_#{SecureRandom.hex(12)}" : "toolu_#{SecureRandom.hex(12)}"),
                       name:  tool_call[:name],
                       input: tool_call[:arguments] || {}
                     }
                   })
            end

            def on_tool_call_delta(block_index:, partial_arguments_json:)
              emit('content_block_delta', {
                     type:  'content_block_delta',
                     index: block_index,
                     delta: { type: 'input_json_delta', partial_json: partial_arguments_json }
                   })
            end

            def on_tool_call_close(block_index:)
              emit('content_block_stop', { type: 'content_block_stop', index: block_index })
            end

            def on_server_tool_result(block_index:, tool_call_id:, result_text:)
              emit('content_block_start', {
                     type:          'content_block_start',
                     index:         block_index,
                     content_block: { type: 'server_tool_result', id: tool_call_id, content: [] }
                   })
              emit('content_block_delta', {
                     type:  'content_block_delta',
                     index: block_index,
                     delta: { type: 'content_block_delta', content: [{ type: 'text', text: result_text }] }
                   })
              emit('content_block_stop', { type: 'content_block_stop', index: block_index })
            end

            def on_keep_alive
              emit('ping', { type: 'ping' })
            end

            def on_message_delta(stop_reason:, output_tokens:)
              emit('message_delta', {
                     type:  'message_delta',
                     delta: { stop_reason: STOP_REASON_MAP[stop_reason] || 'end_turn', stop_sequence: nil },
                     usage: { output_tokens: output_tokens.to_i }
                   })
            end

            def on_done(stop_reason:, usage:, model:)
              _ = stop_reason
              _ = usage
              _ = model
              emit('message_stop', { type: 'message_stop' })
            end

            def on_error(message:, type:, status_code:)
              _ = status_code
              emit('error', { type: 'error', error: { type: type, message: message } })
            end

            private

            def emit(event_name, payload)
              @out << "event: #{event_name}\ndata: #{Legion::JSON.dump(payload)}\n\n"
            end
          end

          # Per the spec equivalence invariant (G21): /v1/messages and
          # /v1/responses with semantically equivalent payloads must parse to
          # canonically equal Canonical::Request structs.
          def format_chunk(canonical_chunk)
            return nil if canonical_chunk.nil?

            case canonical_chunk.type
            when :text_delta
              {
                type:  'content_block_delta',
                index: canonical_chunk.block_index || 0,
                delta: { type: 'text_delta', text: canonical_chunk.delta.to_s }
              }
            when :thinking_delta
              {
                type:  'content_block_delta',
                index: canonical_chunk.block_index || 0,
                delta: { type: 'thinking_delta', thinking: canonical_chunk.delta.to_s }
              }
            when :tool_call_delta
              format_tool_call_delta_chunk(canonical_chunk)
            when :done
              { type: 'message_stop' }
            end
          end

          # G24 — when the canonical chunk carries a server-executed tool
          # (registry/special/extension/mcp source) the streaming surface is
          # `content_block_start` with `server_tool_use` rather than
          # `input_json_delta`. The accompanying server_tool_result emits as
          # a sibling block on close (handled by the StreamAssembler which
          # owns block-index bookkeeping). This single-chunk shape just
          # surfaces the call shape so consumers can preview names/args
          # without buffering through the assembler.
          def format_tool_call_delta_chunk(canonical_chunk)
            tc = canonical_chunk.tool_call
            args = tc.respond_to?(:arguments) ? tc.arguments : {}
            block_index = canonical_chunk.block_index || 0

            if server_tool_chunk?(tc)
              {
                type:          'content_block_start',
                index:         block_index,
                content_block: {
                  type:  'server_tool_use',
                  id:    tc.respond_to?(:id) ? tc.id : nil,
                  name:  tc.respond_to?(:name) ? tc.name.to_s : '',
                  input: args_as_object(args)
                }
              }
            else
              {
                type:  'content_block_delta',
                index: block_index,
                # Anthropic streaming partial_json is a String fragment that
                # accumulates into a JSON object — wire-spec is string here,
                # the assembled object is what input becomes when the block
                # closes. args_as_json_string is the right helper.
                delta: { type: 'input_json_delta', partial_json: args_as_json_string(args) }
              }
            end
          end

          def server_tool_chunk?(tool_call)
            source = tool_call.respond_to?(:source) ? tool_call.source : nil
            return false if source.nil?

            type = source.is_a?(Hash) ? (source[:type] || source['type']) : source
            %i[special registry extension mcp].include?(type&.to_sym)
          end

          private

          def emit(event_name, payload)
            "event: #{event_name}\ndata: #{Legion::JSON.dump(payload)}\n\n"
          end

          def symbolize(body)
            return {} if body.nil?
            return body.transform_keys(&:to_sym) if body.respond_to?(:transform_keys)

            body
          end

          def resolve_conversation_id(body, env)
            env['HTTP_X_LEGION_CONVERSATION_ID'] ||
              body[:conversation_id] ||
              env['HTTP_THREAD_ID'] ||
              env['HTTP_X_CLAUDE_CODE_SESSION_ID'] ||
              "conv_#{SecureRandom.hex(8)}"
          end

          def extract_external_refs(body, env)
            refs = {
              body_conversation_id: body[:conversation_id],
              http_thread_id:       env['HTTP_THREAD_ID'],
              claude_session_id:    env['HTTP_X_CLAUDE_CODE_SESSION_ID'],
              client_request_id:    env['HTTP_X_CLIENT_REQUEST_ID']
            }.compact
            refs.empty? ? nil : refs
          end

          # Anthropic content blocks (assistant/user) map to canonical messages
          # one-to-one for assistant; user messages with tool_result blocks
          # split into multiple :tool messages. Inference messages are still
          # plain hashes today; we build Canonical::Message structs for the
          # canonical request and convert in build_inference_request.
          def extract_messages(raw_messages)
            raw_messages.flat_map { |m| normalize_message(m) }
          end

          def normalize_message(msg)
            msg = symbolize(msg)
            role = msg[:role].to_sym
            content = msg[:content]

            case role
            when :assistant
              normalize_assistant_message(content)
            when :user
              normalize_user_message(content)
            else
              [{ role: role, content: extract_text_content(content) }]
            end
          end

          def normalize_assistant_message(content)
            return [{ role: :assistant, content: content }] if content.is_a?(String)
            return [{ role: :assistant, content: content.to_s }] unless content.is_a?(Array)

            text_parts = []
            tool_calls = []

            content.each do |block|
              bs = symbolize(block)
              type = bs[:type].to_s
              case type
              when 'text'
                text_parts << bs[:text].to_s
              when 'tool_use'
                tool_calls << { id: bs[:id], name: bs[:name], arguments: bs[:input] || {} }
              when 'thinking', 'redacted_thinking'
                # Carry thinking via canonical Thinking on the request — for
                # multi-turn replay R5 says signatures must round-trip on
                # same-provider; leave them in the message for now (the
                # provider translator drops them for cross-provider).
                next
              end
            end

            msg = { role: :assistant, content: text_parts.join("\n\n") }
            msg[:tool_calls] = tool_calls if tool_calls.any?
            [msg]
          end

          def normalize_user_message(content)
            return [{ role: :user, content: content }] if content.is_a?(String)
            return [{ role: :user, content: content.to_s }] unless content.is_a?(Array)

            messages = []
            text_parts = []

            content.each do |block|
              bs = symbolize(block)
              type = bs[:type].to_s
              case type
              when 'text'
                text_parts << bs[:text].to_s
              when 'tool_result'
                if text_parts.any?
                  messages << { role: :user, content: text_parts.join("\n\n") }
                  text_parts = []
                end
                result_content = bs[:content]
                messages << if result_content.is_a?(Array)
                              { role: :tool, tool_call_id: bs[:tool_use_id], content: result_content }
                            else
                              { role: :tool, tool_call_id: bs[:tool_use_id], content: result_content.to_s }
                            end
              else
                text_parts << bs.to_s
              end
            end

            messages << { role: :user, content: text_parts.join } if text_parts.any?
            messages.empty? ? [{ role: :user, content: '' }] : messages
          end

          def extract_text_content(content)
            return content if content.is_a?(String)
            return content.to_s unless content.is_a?(Array)

            content.filter_map do |block|
              bs = symbolize(block)
              bs[:text].to_s if bs[:type].to_s == 'text'
            end.join
          end

          def extract_system(sys)
            return nil if sys.nil?
            return sys if sys.is_a?(String)

            if sys.is_a?(Array)
              text_blocks = sys.select { |b| symbolize(b)[:type].to_s == 'text' }
              text_blocks.map { |b| symbolize(b)[:text] }.join("\n\n")
            else
              sys.to_s
            end
          end

          # Anthropic tool definitions use `input_schema`; canonicalize to
          # parameters: at the canonical layer.
          def extract_tools(raw)
            return nil unless raw.is_a?(Array) && !raw.empty?

            raw.map do |t|
              ts = symbolize(t)
              {
                name:        ts[:name].to_s,
                description: ts[:description].to_s,
                parameters:  ts[:input_schema] || ts[:parameters] || {},
                source:      { type: :client, executable: false }
              }
            end
          end

          def extract_params(body)
            params = {
              max_tokens:     body[:max_tokens],
              temperature:    body[:temperature],
              top_p:          body[:top_p],
              top_k:          body[:top_k],
              stop_sequences: body[:stop_sequences]
            }.compact
            params.empty? ? nil : params
          end

          # Map an Anthropic-style thinking block ({type:, budget_tokens:}) to
          # the canonical {effort:, budget:} kwargs that
          # Canonical::ThinkingConfig.new accepts. Anthropic doesn't carry an
          # effort spelling — only a budget — so effort stays nil.
          def extract_thinking(thinking)
            return nil if thinking.nil?

            if thinking.is_a?(Hash)
              h = thinking.transform_keys(&:to_sym)
              return nil if h[:type].to_s == 'disabled'

              budget = h[:budget] || h[:budget_tokens]
              effort = h[:effort]
              return nil if budget.nil? && effort.nil?

              { effort: effort, budget: budget }.compact
            else
              # Anything else is a "thinking is on" flag — no concrete budget.
              { effort: thinking.to_s }
            end
          end

          # Canonical::ThinkingConfig#to_h is {effort:, budget:}. The Inference
          # request and downstream provider translators expect the
          # Anthropic-style {type: 'enabled', budget_tokens:} shape; map back.
          def thinking_to_inference(thinking_obj)
            return nil if thinking_obj.nil?

            h = thinking_obj.respond_to?(:to_h) ? thinking_obj.to_h : thinking_obj
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
                description: (hash[:description] || '').to_s,
                parameters:  hash[:parameters] || {},
                source:      { type: :client, executable: false, raw_name: hash[:name].to_s }
              )
            rescue StandardError => e
              handle_exception(e, level: :warn, handled: true,
                                  operation: 'llm.client_translator.anthropic.build_tool', tool_name: hash[:name])
              nil
            end
          end

          # Canonical messages → plain hashes the executor's Inference::Request
          # currently expects. Round-trips text/tool_calls/tool_call_id.
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

          def build_content(pipeline_response)
            tool_calls = extract_tool_calls(pipeline_response)
            blocks = []

            thinking_block = thinking_content_block(pipeline_response)
            blocks << thinking_block if thinking_block

            text = pipeline_response.respond_to?(:message) ? pipeline_response.message : nil
            text_content = if text.is_a?(Hash)
                             (text[:content] || text['content']).to_s
                           else
                             text.to_s
                           end

            blocks << { type: 'text', text: text_content } unless text_content.empty? && !tool_calls.empty?

            tool_calls.each do |tc|
              # Anthropic wire: tool_use.input MUST be an object. A degraded
              # provider output (raw numeric, unparsed JSON string) coerces to
              # `{}` rather than violating the contract. The matrix harness
              # asserts this typing per format (P6F2).
              input = args_as_object(tc[:arguments])
              if tc[:server_tool]
                blocks << { type: 'server_tool_use', id: tc[:id], name: tc[:name], input: input }
                if tc[:result]
                  blocks << {
                    type:    'server_tool_result',
                    id:      tc[:id],
                    content: [{ type: 'text', text: serialize_result(tc[:result]) }]
                  }
                end
              else
                blocks << { type: 'tool_use', id: tc[:id], name: tc[:name], input: input }
              end
            end

            blocks.empty? ? [{ type: 'text', text: '' }] : blocks
          end

          def thinking_content_block(pipeline_response)
            thinking = pipeline_response.respond_to?(:thinking) ? pipeline_response.thinking : nil
            return nil if thinking.nil?

            normalized = if thinking.is_a?(Hash)
                           thinking.transform_keys { |k| k.respond_to?(:to_sym) ? k.to_sym : k }
                         else
                           { content: thinking.respond_to?(:content) ? thinking.content : thinking.to_s }
                         end

            content = normalized[:content].to_s
            signature = normalized[:signature].to_s

            return nil if content.empty? && signature.empty?

            block = { type: 'thinking', thinking: content }
            block[:signature] = signature unless signature.empty?
            block
          end

          def extract_tool_calls(pipeline_response)
            tools = pipeline_response.respond_to?(:tools) ? pipeline_response.tools : nil
            return [] if tools.nil?

            Array(tools).map do |tc|
              source = if tc.respond_to?(:source)
                         tc.source
                       else
                         (tc.is_a?(Hash) ? tc[:source] : nil)
                       end
              {
                id:          tc.respond_to?(:id) ? tc.id : (tc[:id] if tc.is_a?(Hash)),
                name:        tc.respond_to?(:name) ? tc.name : (tc[:name] if tc.is_a?(Hash)),
                arguments:   tc.respond_to?(:arguments) ? tc.arguments : (tc[:arguments] if tc.is_a?(Hash)),
                result:      tc.respond_to?(:result) ? tc.result : (tc[:result] if tc.is_a?(Hash)),
                server_tool: server_tool_source?(source)
              }
            end
          end

          def server_tool_source?(source)
            return false if source.nil?

            type = source.is_a?(Hash) ? (source[:type] || source['type']) : source
            %i[special registry extension mcp].include?(type&.to_sym)
          end

          def format_stop_reason(pipeline_response)
            tool_calls = extract_tool_calls(pipeline_response)

            pending_legionio = tool_calls.select { |tc| tc[:server_tool] && tc[:result].nil? }
            return 'pause_turn' if pending_legionio.any?
            return 'tool_use' if tool_calls.any? { |tc| !tc[:server_tool] && tc[:result].nil? }

            stop = pipeline_response.respond_to?(:stop) ? pipeline_response.stop : nil
            reason = stop.is_a?(Hash) ? (stop[:reason] || stop['reason']) : stop.to_s
            case reason.to_s
            when 'tool_use'       then 'tool_use'
            when 'max_tokens'     then 'max_tokens'
            when 'content_filter' then 'content_filter'
            when 'stop'
              pipeline_response.respond_to?(:stop_sequence) && pipeline_response.stop_sequence ? 'stop_sequence' : 'end_turn'
            else 'end_turn'
            end
          end

          def serialize_result(result)
            return result if result.is_a?(String)

            Legion::JSON.dump(result)
          rescue StandardError
            result.to_s
          end
        end
      end
    end
  end
end
