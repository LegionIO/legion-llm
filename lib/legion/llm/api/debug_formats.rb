# frozen_string_literal: true

require 'legion/logging/helper'
require 'legion/extensions/llm'
require 'legion/llm/call/dispatch'

module Legion
  module LLM
    module API
      # Shared X-Legion-Format / X-Legion-Debug surface for the three client
      # routes (G21).
      #
      # Two opt-in debug modes, both gated by `llm.api.debug_formats.enabled`
      # (default: true in lite/dev, false otherwise — the envelope leaks
      # routing/escalation internals):
      #
      #   X-Legion-Format: canonical
      #     Run the full pipeline but skip the client-format translation.
      #     Sync: return Canonical::Response#to_h + contract version.
      #     Streaming: emit each canonical chunk as `data: <chunk-json>\n\n`
      #     followed by `data: [DONE]\n\n` — same envelope across all three
      #     routes (no Anthropic-style typed events, no /v1/responses
      #     sequence_number ceremony) so the canonical layer is its own
      #     bisection point.
      #
      #   X-Legion-Debug: echo-request
      #     The parsed Canonical::Request#to_h is folded into the response
      #     metadata under `_legion_debug.echo_request`. Combined with
      #     X-Legion-Format: canonical, this is the equivalence-invariant
      #     check — the same semantic payload sent to /v1/messages and
      #     /v1/responses must echo back IDENTICAL Canonical::Request hashes.
      #
      # Modes are independent: `format=canonical` works without the echo, and
      # `echo-request` works on a normal client-format response.
      module DebugFormats
        extend Legion::Logging::Helper

        Canonical = Legion::Extensions::Llm::Canonical

        FORMAT_HEADER = 'HTTP_X_LEGION_FORMAT'
        DEBUG_HEADER  = 'HTTP_X_LEGION_DEBUG'

        FORMAT_CANONICAL = 'canonical'
        DEBUG_ECHO_REQUEST = 'echo-request'

        # Settings dig — debug surface enabled?
        def self.enabled?
          settings = Legion::Settings[:llm][:api][:debug_formats]
          settings.is_a?(Hash) ? settings[:enabled] == true : false
        end

        def self.canonical_format?(env)
          enabled? && env[FORMAT_HEADER].to_s.downcase == FORMAT_CANONICAL
        end

        def self.echo_request?(env)
          enabled? && env[DEBUG_HEADER].to_s.downcase == DEBUG_ECHO_REQUEST
        end

        # Render a non-streaming canonical response as JSON. Returns
        # [status, headers, body_string] suitable for use in a Sinatra action.
        def self.render_canonical_response(pipeline_response, canonical_request:, env:)
          canonical_response = canonicalize_response(pipeline_response)
          payload = {
            object:           'canonical.response',
            contract_version: Canonical::CONTRACT_VERSION,
            response:         canonical_response.to_h
          }
          payload[:_legion_debug] = { echo_request: canonical_request.to_h } if echo_request?(env)
          [200,
           { 'Content-Type'              => 'application/json',
             'X-Legion-Contract-Version' => Canonical::CONTRACT_VERSION },
           Legion::JSON.dump(payload)]
        end

        # Streaming canonical SSE — emit each chunk via the assembler-equivalent
        # stream interface, then a final `data: [DONE]\n\n`. Same envelope on
        # every route.
        def self.canonical_event_emitter(out)
          CanonicalEvents.new(out)
        end

        # Sync: fold the parsed canonical request into a client-format
        # response's metadata. Mutates a copy of the body to keep callers
        # simple. Returns the merged hash.
        def self.attach_echo_request(client_format_body, canonical_request)
          {
            **client_format_body,
            _legion_debug: { echo_request: canonical_request.to_h }
          }
        end

        # Streaming: emit a one-shot SSE event with the canonical request echo
        # so the client can correlate the two endpoints. Best-effort; non-fatal
        # on write failure.
        def self.emit_echo_request_sse(out, canonical_request)
          out << "event: legion.debug.echo_request\ndata: #{Legion::JSON.dump(canonical_request.to_h)}\n\n"
        rescue IOError, Errno::EPIPE
          nil
        end

        # Convert an Inference::Response (the executor's envelope) into a
        # Canonical::Response (the provider-boundary contract).
        # Inference::Response carries the executor envelope — text, tool_calls,
        # thinking, usage live on it; Canonical::Response is the projection.
        def self.canonicalize_response(pipeline_response)
          message = pipeline_response.respond_to?(:message) ? pipeline_response.message : nil
          text = if message.is_a?(Hash)
                   (message[:content] || message['content']).to_s
                 else
                   message.to_s
                 end

          tokens = pipeline_response.respond_to?(:tokens) ? pipeline_response.tokens || {} : {}
          usage = canonical_usage(tokens, pipeline_response)

          tool_calls = (pipeline_response.respond_to?(:tools) ? Array(pipeline_response.tools) : []).map do |tc|
            canonical_tool_call(tc)
          end

          thinking = canonical_thinking(pipeline_response.respond_to?(:thinking) ? pipeline_response.thinking : nil)
          stop_reason = canonical_stop_reason(pipeline_response, tool_calls)
          routing = pipeline_response.respond_to?(:routing) ? pipeline_response.routing || {} : {}
          model = (routing[:model] || routing['model']).to_s

          metadata = {}
          metadata[:request_id] = pipeline_response.request_id if pipeline_response.respond_to?(:request_id)
          metadata[:conversation_id] = pipeline_response.conversation_id if pipeline_response.respond_to?(:conversation_id)
          metadata[:routing] = sanitize_routing(routing) if routing.any?

          Canonical::Response.build(
            text:        text,
            thinking:    thinking,
            tool_calls:  tool_calls,
            usage:       usage,
            stop_reason: stop_reason,
            model:       model,
            routing:     sanitize_routing(routing),
            metadata:    metadata
          )
        end

        # Canonical streaming emitter — implements the StreamAssembler emitter
        # contract but writes canonical chunk hashes (not client-format
        # events). Same envelope across /v1/messages, /v1/responses, and
        # /v1/chat/completions.
        class CanonicalEvents
          def initialize(out)
            @out = out
            @done_emitted = false
          end

          def on_start(model:, request_id:, input_tokens:)
            emit_event({
                         type:             'start',
                         contract_version: DebugFormats::Canonical::CONTRACT_VERSION,
                         request_id:       request_id,
                         model:            model.to_s,
                         input_tokens:     input_tokens.to_i
                       })
          end

          def on_text_open(block_index:)
            emit_event({ type: 'text_open', block_index: block_index })
          end

          def on_text_delta(block_index:, text:)
            emit_event({ type: 'text_delta', block_index: block_index, delta: text })
          end

          def on_text_close(block_index:)
            emit_event({ type: 'text_close', block_index: block_index })
          end

          def on_thinking_open(block_index:)
            emit_event({ type: 'thinking_open', block_index: block_index })
          end

          def on_thinking_delta(block_index:, text:, signature:)
            payload = { type: 'thinking_delta', block_index: block_index, delta: text }
            payload[:signature] = signature unless signature.to_s.empty?
            emit_event(payload)
          end

          def on_thinking_close(block_index:, signature:)
            payload = { type: 'thinking_close', block_index: block_index }
            payload[:signature] = signature unless signature.to_s.empty?
            emit_event(payload)
          end

          def on_tool_call_open(block_index:, tool_call:, server_tool:)
            emit_event({
                         type:        'tool_call_open',
                         block_index: block_index,
                         tool_call:   {
                           id:        tool_call[:id],
                           name:      tool_call[:name],
                           arguments: tool_call[:arguments] || {}
                         },
                         server_tool: server_tool
                       })
          end

          def on_tool_call_delta(block_index:, partial_arguments_json:)
            emit_event({
                         type:                   'tool_call_delta',
                         block_index:            block_index,
                         partial_arguments_json: partial_arguments_json
                       })
          end

          def on_tool_call_close(block_index:)
            emit_event({ type: 'tool_call_close', block_index: block_index })
          end

          def on_tool_call_abort(block_index:, reason:)
            emit_event({ type: 'tool_call_abort', block_index: block_index, reason: reason })
          end

          def on_server_tool_result(block_index:, tool_call_id:, result_text:)
            emit_event({
                         type:         'server_tool_result',
                         block_index:  block_index,
                         tool_call_id: tool_call_id,
                         result:       result_text
                       })
          end

          def on_keep_alive
            @out << ": keep-alive\n\n"
          end

          def on_message_delta(stop_reason:, output_tokens:)
            emit_event({ type: 'message_delta', stop_reason: stop_reason, output_tokens: output_tokens.to_i })
          end

          def on_done(stop_reason:, usage:, model:)
            return if @done_emitted

            emit_event({
                         type:        'done',
                         stop_reason: stop_reason,
                         usage:       usage,
                         model:       model.to_s
                       })
            @out << "data: [DONE]\n\n"
            @done_emitted = true
          end

          def on_error(message:, type:, status_code:)
            emit_event({ type: 'error', error: { message: message, kind: type, status: status_code } })
            @out << "data: [DONE]\n\n" unless @done_emitted
            @done_emitted = true
          end

          private

          def emit_event(payload)
            @out << "data: #{Legion::JSON.dump(payload)}\n\n"
          end
        end

        def self.canonical_thinking(value)
          return nil if value.nil?

          if value.is_a?(Hash)
            normalized = value.transform_keys { |k| k.respond_to?(:to_sym) ? k.to_sym : k }
            content = (normalized[:content] || normalized[:text] || normalized[:thinking]).to_s
            signature = normalized[:signature].to_s
          else
            content = value.respond_to?(:content) ? value.content.to_s : value.to_s
            signature = value.respond_to?(:signature) ? value.signature.to_s : ''
          end
          return nil if content.empty? && signature.empty?

          Canonical::Thinking.from_hash(content: content, signature: signature)
        end

        def self.canonical_tool_call(tool_call)
          return tool_call if tool_call.is_a?(Canonical::ToolCall)

          h = tool_call.respond_to?(:to_h) && !tool_call.is_a?(Hash) ? tool_call.to_h : tool_call
          h = if h.is_a?(Hash)
                h.transform_keys { |k| k.respond_to?(:to_sym) ? k.to_sym : k }
              else
                {}
              end

          source = h[:source]
          source_sym = if source.is_a?(Hash)
                         (source[:type] || source['type'])&.to_sym
                       else
                         source&.to_sym
                       end

          Canonical::ToolCall.build(
            id:        h[:id],
            name:      h[:name].to_s,
            arguments: h[:arguments] || {},
            source:    source_sym,
            status:    h[:status],
            result:    h[:result]
          )
        end

        def self.canonical_usage(tokens, _pipeline_response)
          return nil if tokens.nil? || (tokens.respond_to?(:empty?) && tokens.empty?)

          Canonical::Usage.from_hash(
            input_tokens:       token_value(tokens, :input, :input_tokens) || 0,
            output_tokens:      token_value(tokens, :output, :output_tokens) || 0,
            cache_read_tokens:  token_value(tokens, :cache_read, :cache_read_tokens) || 0,
            cache_write_tokens: token_value(tokens, :cache_write, :cache_write_tokens) || 0,
            thinking_tokens:    token_value(tokens, :thinking, :thinking_tokens) || 0
          )
        end

        def self.canonical_stop_reason(pipeline_response, tool_calls)
          return :tool_use if tool_calls.any? { |tc| tc.source != :special && tc.source != :registry && tc.source != :extension && tc.source != :mcp && tc.result.nil? }

          stop = pipeline_response.respond_to?(:stop) ? pipeline_response.stop : nil
          reason = stop.is_a?(Hash) ? (stop[:reason] || stop['reason']) : stop
          sym = reason&.to_sym
          return sym if Canonical::Response::STOP_REASONS.include?(sym)

          :end_turn
        end

        def self.sanitize_routing(routing)
          return {} if routing.nil? || routing.empty?

          {
            provider: routing[:provider] || routing['provider'],
            model:    routing[:model]    || routing['model'],
            tier:     routing[:tier]     || routing['tier'],
            instance: routing[:instance] || routing['instance']
          }.compact
        end

        def self.token_value(tokens, *keys)
          return nil if tokens.nil?

          keys.each do |key|
            value = if tokens.is_a?(Hash)
                      tokens[key] || tokens[key.to_s]
                    elsif tokens.respond_to?(key)
                      tokens.public_send(key)
                    end
            return value.to_i unless value.nil?
          end
          nil
        end
      end
    end
  end
end
