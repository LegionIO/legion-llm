# frozen_string_literal: true

require 'legion/logging/helper'
require 'legion/llm/api/client_translators/shared_extractors'

module Legion
  module LLM
    module API
      # Single SSE state machine for client-format streaming.
      #
      # Per design 2026-06-09 R5/G6:
      #   - block index bookkeeping (one place, not per-route)
      #   - thinking-before-text ordering
      #   - fallback text emission (when provider returned no chunks)
      #   - server tool result emission (LegionIO tools execute server-side and
      #     emit their result inline)
      #   - push raises StreamClosed after client disconnect — caller treats as
      #     cancellation per G10
      #   - finalize no-ops when closed
      #   - provider-error mid-stream emits client-format error event after
      #     failover ladder is exhausted (G6)
      #   - failover phase points: before-first-byte / mid-text / mid-thinking /
      #     mid-tool-call (the assembler tracks the current phase so the
      #     escalation chain knows what to replay)
      #
      # Chunk shape: the assembler accepts canonical chunks
      # (Legion::Extensions::Llm::Canonical::Chunk, post P3 translators) and the
      # legacy provider StreamChunk (lex-llm Responses::StreamChunk). The
      # ChunkAdapter normalizes both to a tiny internal struct so the state
      # machine has one shape to reason about.
      class StreamAssembler
        extend Legion::Logging::Helper
        include Legion::Logging::Helper
        include Legion::LLM::API::ClientTranslators::SharedExtractors

        class StreamClosed < StandardError; end

        # Emitter contract — every client format implements:
        #   on_start(model:, request_id:, input_tokens:)
        #   on_text_open(block_index:)                   — content_block_start text
        #   on_text_delta(block_index:, text:)
        #   on_text_close(block_index:)
        #   on_thinking_open(block_index:)
        #   on_thinking_delta(block_index:, text:, signature:)
        #   on_thinking_close(block_index:, signature:)
        #   on_tool_call_open(block_index:, tool_call:, server_tool:)
        #   on_tool_call_delta(block_index:, partial_arguments_json:)
        #   on_tool_call_close(block_index:)
        #   on_server_tool_result(block_index:, tool_call_id:, result_text:)
        #   on_keep_alive
        #   on_message_delta(stop_reason:, output_tokens:)
        #   on_done(stop_reason:, usage:, model:)
        #   on_error(message:, type:, status_code:)
        #
        # Emitters write to the response stream directly; they don't return
        # values. The assembler catches IOError/EPIPE and flips into closed
        # state.
        attr_reader :phase

        # Phases per G6 — failover ladder branches on this.
        PHASES = %i[
          before_first_byte
          mid_text
          mid_thinking
          mid_tool_call
          finished
        ].freeze

        # H-I / sonnet G6 / D-K: initial_lane required so the assembler always has a lane on hand.
        # Passing initial_lane: nil raises ArgumentError.
        def initialize(emitter:, request_id:, model:, input_tokens: 0,
                       emit_thinking_blocks: nil, tool_call_buffering: nil,
                       keep_alive_interval_ms: nil, initial_lane: nil, **)
          raise ArgumentError, 'initial_lane: must be a non-nil lane Hash' if initial_lane.nil?

          @emitter = emitter
          @request_id = request_id
          @model = model.to_s
          @input_tokens = input_tokens.to_i

          # G30 / D-F: failover tracking for debug trailers. @current_lane tracks the
          # active dispatch lane; @failover_chain records lane IDs for the x-legion-failover-*
          # debug trailers emitted at finalize time. NO custom SSE event (N×N invariant 5).
          @current_lane = initial_lane
          @failover_chain = [initial_lane.is_a?(Hash) ? initial_lane[:id] : initial_lane.to_s]

          settings = Legion::Settings[:llm][:streaming] || {}
          @emit_thinking_blocks = if emit_thinking_blocks.nil?
                                    settings[:emit_thinking_blocks] == true
                                  else
                                    emit_thinking_blocks
                                  end
          @tool_call_buffering = (tool_call_buffering || settings[:tool_call_buffering] || :buffered).to_sym
          @keep_alive_interval_ms = (keep_alive_interval_ms || settings[:keep_alive_interval_ms] || 5_000).to_i

          @phase = :before_first_byte
          @closed = false
          @started = false
          @next_block_index = 0
          @text_block_index = nil
          @thinking_block_index = nil
          @text_block_open = false
          @thinking_block_open = false
          @thinking_block_closed = false
          @full_text = +''
          @full_thinking = +''
          @full_thinking_signature = nil
          @open_tool_calls = {} # tool_call_id => { block_index:, name:, server_tool:, last_args_str: }
          @last_keep_alive_at = nil
        end

        def closed?
          @closed
        end

        # Begin the SSE response. Idempotent; safe to call from finalize too.
        def start!
          return if @started || @closed

          guard { @emitter.on_start(model: @model, request_id: @request_id, input_tokens: @input_tokens) }
          @started = true
        end

        # Consume one chunk. Raises StreamClosed if the client disconnected.
        # Returns nil; emission happens through the emitter callbacks.
        def push(chunk)
          raise StreamClosed if @closed

          start! unless @started

          adapted = ChunkAdapter.normalize(chunk)
          return if adapted.nil?

          # Tool call deltas may arrive interleaved with text/thinking — the
          # state machine flushes text/thinking blocks first then opens the
          # tool block.
          if adapted.tool_calls.any?
            close_text_block
            close_thinking_block
            adapted.tool_calls.each { |tc| handle_tool_call_delta(tc) }
          end

          if adapted.thinking_text && !adapted.thinking_text.empty?
            handle_thinking_delta(adapted.thinking_text, adapted.thinking_signature)
          elsif adapted.thinking_signature && !adapted.thinking_signature.to_s.empty?
            @full_thinking_signature ||= adapted.thinking_signature.to_s
          end

          handle_text_delta(adapted.text) if adapted.text && !adapted.text.empty?
        rescue StreamClosed
          raise
        rescue IOError, Errno::EPIPE => e
          mark_closed!(e)
          raise StreamClosed, e.message
        end

        # Close the SSE stream. No-ops on a closed stream (per R5).
        # final_response is the executor's pipeline response (carries
        # tool_calls, thinking, stop_reason, tokens for the trailer events).
        def finalize(final_response)
          return if @closed

          start! unless @started

          handle_final_thinking(final_response) if @emit_thinking_blocks
          close_thinking_block

          tool_calls = extract_tool_calls(final_response)

          # Emit a fallback text block when nothing was streamed and there are
          # no tool calls — protects against providers that batched everything
          # into a non-streaming-shaped final response.
          emit_fallback_text(final_response) if !@text_block_open && @full_text.empty? && tool_calls.empty?

          close_text_block

          tool_calls.each { |tc| emit_terminal_tool_call(tc) }

          stop_reason = final_response_stop_reason(final_response, tool_calls)
          usage = final_response_usage(final_response)
          guard { @emitter.on_message_delta(stop_reason: stop_reason, output_tokens: usage[:output_tokens]) }
          guard { @emitter.on_done(stop_reason: stop_reason, usage: usage, model: resolved_model(final_response)) }
          emit_failover_trailers!
          @phase = :finished
        rescue IOError, Errno::EPIPE => e
          mark_closed!(e)
        end

        # Handle a provider-error after the failover ladder is exhausted (G6).
        # Emits the client-format error event so the client sees a clean
        # failure rather than a truncated stream.
        def on_failover_exhausted(error, status: 502, type: 'overloaded_error')
          return if @closed

          start! unless @started
          guard { @emitter.on_error(message: error.message, type: type, status_code: status) }
          @phase = :finished
        rescue IOError, Errno::EPIPE => e
          mark_closed!(e)
        end

        attr_reader :failover_events

        def provider_failed(error:, resolution:)
          return if @closed

          @failover_events ||= []
          @failover_events << {
            provider: resolution.provider,
            instance: resolution.instance,
            model:    resolution.model,
            phase:    @phase,
            error:    error.class.name
          }

          case @phase
          when :before_first_byte
            keep_alive! if @started
          when :mid_text
            close_text_block
          when :mid_thinking
            close_thinking_block
          when :mid_tool_call
            abort_open_tool_calls(reason: error.class.name)
          end
        end

        def provider_switched(from:, to:) # rubocop:disable Lint/UnusedMethodArgument
          return if @closed

          @model = to.model.to_s
          keep_alive! if @started && @phase != :finished
          @phase = :before_first_byte if @phase == :mid_tool_call
        end

        # G30 / D-F / N×N invariant 5: mid-stream failover is silent at the SSE wire.
        # Clears the partial canonical buffer so the next provider renders a clean start.
        # Appends a failover marker to @failover_chain for debug trailers at finalize.
        # NO custom SSE event is emitted — that would violate N×N "always translate".
        def provider_failover_pending!(from:, **)
          return if @closed

          from_id = from.is_a?(Hash) ? from[:id] : from.to_s
          log.warn('[llm][stream_assembler] action=provider_failover_pending ' \
                   "from=#{from_id} request_id=#{@request_id}")
          # Clear the partial canonical buffer — partial responses can't cross providers
          # (thinking strip, context invalidation). The next provider starts fresh.
          close_thinking_block if @thinking_block_open
          close_text_block     if @text_block_open
          abort_open_tool_calls(reason: 'provider_failover')
          @full_text.clear
          @full_thinking.clear
          @full_thinking_signature = nil
          @phase = :before_first_byte
          @failover_chain << :failover_marker
        rescue IOError, Errno::EPIPE => e
          mark_closed!(e)
        end

        # Called by the executor after selecting the next lane. Updates @current_lane
        # and appends the new lane ID to the failover chain for debug trailers.
        def begin_dispatch_on(lane:, **)
          return if @closed

          @current_lane = lane
          @failover_chain << (lane.is_a?(Hash) ? lane[:id] : lane.to_s)
          log.info("[llm][stream_assembler] action=begin_dispatch lane=#{lane.is_a?(Hash) ? lane[:id] : lane} " \
                   "request_id=#{@request_id}")
        end

        def safe_replay_snapshot
          {
            emitted_text:               @full_text.dup,
            thinking_emitted:           @thinking_block_open || @thinking_block_closed,
            thinking_signature_present: !@full_thinking_signature.to_s.empty?,
            open_tool_call_count:       @open_tool_calls.size,
            phase:                      @phase
          }
        end

        # Emitters call this to send a keep-alive ping while a buffered tool
        # call is being assembled (so large tool args don't make the provider
        # look dead, per G6c). The assembler invokes it from push() when it
        # detects mid-tool-call gaps; keeping it public lets routes call it
        # directly during long executor pre-steps too.
        def keep_alive!
          return if @closed

          guard { @emitter.on_keep_alive }
        rescue IOError, Errno::EPIPE => e
          mark_closed!(e)
        end

        private

        # G30 / D-F: emit x-legion-failover-* debug trailers after on_done.
        # Only fires when failover actually happened (@failover_chain has markers).
        # Trailers are response metadata, not SSE events — no wire-level event emitted.
        def emit_failover_trailers!
          failover_count = @failover_chain.count(:failover_marker)
          return if failover_count.zero?
          return unless @emitter.respond_to?(:on_trailers)

          real_ids = @failover_chain.reject { |e| e == :failover_marker }
          return unless real_ids.size >= 2

          @emitter.on_trailers(trailers: {
                                 'x-legion-failover-from'  => real_ids.first.to_s,
                                 'x-legion-failover-to'    => real_ids.last.to_s,
                                 'x-legion-failover-count' => failover_count.to_s
                               })
        rescue StandardError => e
          handle_exception(e, level: :warn, operation: 'llm.api.stream_assembler.emit_failover_trailers')
        end

        def abort_open_tool_calls(reason:)
          @open_tool_calls.each_value do |state|
            next if @tool_call_buffering == :buffered

            guard { @emitter.on_tool_call_abort(block_index: state[:block_index], reason: reason) } if @emitter.respond_to?(:on_tool_call_abort)
          end
          @open_tool_calls.clear
        end

        def guard
          yield
          true
        rescue IOError, Errno::EPIPE => e
          mark_closed!(e)
          false
        end

        def mark_closed!(error)
          return if @closed

          @closed = true
          handle_exception(error, level: :warn, handled: true,
                              operation: 'llm.api.stream_assembler.disconnect',
                              request_id: @request_id)
        end

        def handle_text_delta(text)
          unless @text_block_open
            @text_block_index = @next_block_index
            @next_block_index += 1
            guard { @emitter.on_text_open(block_index: @text_block_index) }
            @text_block_open = true
          end
          @full_text << text
          @phase = :mid_text
          guard { @emitter.on_text_delta(block_index: @text_block_index, text: text) }
        end

        def handle_thinking_delta(text, signature)
          # Thinking always comes before text per the canonical ordering.
          # When emit_thinking_blocks is off we still accumulate the internal
          # buffer (so finalize can attach it to the final message audit) but
          # never emit blocks to the client.
          @full_thinking << text.to_s unless text.to_s.empty?
          @full_thinking_signature ||= signature.to_s unless signature.to_s.empty?

          return unless @emit_thinking_blocks

          unless @thinking_block_open || @thinking_block_closed
            @thinking_block_index = @next_block_index
            @next_block_index += 1
            guard { @emitter.on_thinking_open(block_index: @thinking_block_index) }
            @thinking_block_open = true
          end

          return if @thinking_block_closed

          @phase = :mid_thinking
          guard { @emitter.on_thinking_delta(block_index: @thinking_block_index, text: text.to_s, signature: signature.to_s) }
        end

        def handle_tool_call_delta(tool_call)
          tc_id = tool_call[:id] || "call_#{tool_call[:name]}_#{@next_block_index}"
          state = @open_tool_calls[tc_id]

          if state.nil?
            block_index = @next_block_index
            @next_block_index += 1
            server_tool = tool_call[:server_tool] == true
            state = {
              block_index:   block_index,
              id:            tc_id,
              name:          tool_call[:name],
              server_tool:   server_tool,
              last_args_str: '',
              arguments:     tool_call[:arguments] || {},
              result:        tool_call[:result]
            }
            @open_tool_calls[tc_id] = state
            @phase = :mid_tool_call

            if @tool_call_buffering == :buffered
              # Buffered: don't open the block until close — keep client alive.
              keep_alive!
              return
            end

            guard do
              @emitter.on_tool_call_open(
                block_index: block_index,
                tool_call:   { id: tc_id, name: tool_call[:name], arguments: state[:arguments] },
                server_tool: server_tool
              )
            end
          end

          # Update accumulated arguments (canonical chunks send the cumulative
          # arguments hash on every delta — see fixture
          # canonical_streaming_tool_call_chunks.json A7 note).
          state[:arguments] = tool_call[:arguments] || state[:arguments]
          state[:result]    = tool_call[:result]    if tool_call.key?(:result)

          return if @tool_call_buffering == :buffered

          # Unbuffered: emit incremental delta. Compute string diff against
          # last emitted args so partial JSON doesn't repeat.
          args_str = serialize_args(state[:arguments])
          delta = args_str.start_with?(state[:last_args_str]) ? args_str[state[:last_args_str].length..] : args_str
          state[:last_args_str] = args_str
          guard { @emitter.on_tool_call_delta(block_index: state[:block_index], partial_arguments_json: delta) }
        end

        def close_text_block
          return unless @text_block_open

          guard { @emitter.on_text_close(block_index: @text_block_index) }
          @text_block_open = false
        end

        def close_thinking_block
          return unless @thinking_block_open && !@thinking_block_closed

          guard { @emitter.on_thinking_close(block_index: @thinking_block_index, signature: @full_thinking_signature.to_s) }
          @thinking_block_closed = true
        end

        def emit_fallback_text(final_response)
          fallback = extract_fallback_text(final_response)
          return if fallback.empty?

          @text_block_index = @next_block_index
          @next_block_index += 1
          @text_block_open = true
          @full_text << fallback
          guard { @emitter.on_text_open(block_index: @text_block_index) }
          guard { @emitter.on_text_delta(block_index: @text_block_index, text: fallback) }
        end

        def handle_final_thinking(final_response)
          return if @thinking_block_open || @thinking_block_closed

          payload = extract_thinking_payload(final_response)
          return unless payload

          text = payload[:content].to_s
          signature = payload[:signature].to_s

          return if text.empty? && signature.empty?

          @thinking_block_index = @next_block_index
          @next_block_index += 1
          guard { @emitter.on_thinking_open(block_index: @thinking_block_index) }
          @thinking_block_open = true
          @full_thinking << text unless text.empty? || @full_thinking.include?(text)
          @full_thinking_signature ||= signature unless signature.empty?
          guard { @emitter.on_thinking_delta(block_index: @thinking_block_index, text: text, signature: signature) } unless text.empty?
        end

        # Emits the final tool-use block(s) for tool calls extracted from the
        # final response. For buffered tool calls this is the only emission;
        # for unbuffered this finalizes any open ones.
        def emit_terminal_tool_call(tool_call)
          existing = @open_tool_calls.values.find { |s| s[:id] == tool_call[:id] }

          if existing && @tool_call_buffering == :buffered
            guard do
              @emitter.on_tool_call_open(
                block_index: existing[:block_index],
                tool_call:   { id: existing[:id], name: existing[:name], arguments: tool_call[:arguments] || existing[:arguments] },
                server_tool: existing[:server_tool]
              )
            end
            guard do
              @emitter.on_tool_call_delta(
                block_index:            existing[:block_index],
                partial_arguments_json: serialize_args(tool_call[:arguments] || existing[:arguments])
              )
            end
            guard { @emitter.on_tool_call_close(block_index: existing[:block_index]) }
            block_index = existing[:block_index]
            server_tool = existing[:server_tool]
          elsif existing
            guard do
              @emitter.on_tool_call_delta(
                block_index:            existing[:block_index],
                partial_arguments_json: serialize_args(tool_call[:arguments] || existing[:arguments])
              )
            end
            guard { @emitter.on_tool_call_close(block_index: existing[:block_index]) }
            block_index = existing[:block_index]
            server_tool = existing[:server_tool]
          else
            block_index = @next_block_index
            @next_block_index += 1
            server_tool = tool_call[:server_tool] == true
            guard do
              @emitter.on_tool_call_open(
                block_index: block_index,
                tool_call:   tool_call,
                server_tool: server_tool
              )
            end
            guard { @emitter.on_tool_call_delta(block_index: block_index, partial_arguments_json: serialize_args(tool_call[:arguments] || {})) }
            guard { @emitter.on_tool_call_close(block_index: block_index) }
          end

          # Server tool result inline emission (Anthropic server_tool_result).
          return unless server_tool

          result = tool_call[:result]
          return if result.nil?

          result_block = @next_block_index
          @next_block_index += 1
          guard do
            @emitter.on_server_tool_result(
              block_index:  result_block,
              tool_call_id: tool_call[:id],
              result_text:  serialize_result(result)
            )
          end
        end

        def extract_tool_calls(final_response)
          tools = final_response.respond_to?(:tools) ? final_response.tools : nil
          return [] unless tools.respond_to?(:any?) && tools.any?

          tools.map do |tc|
            id        = tc.respond_to?(:id) ? tc.id : (tc[:id] || tc['id'])
            name      = tc.respond_to?(:name) ? tc.name : (tc[:name] || tc['name'])
            arguments = tc.respond_to?(:arguments) ? tc.arguments : (tc[:arguments] || tc['arguments'] || {})
            result    = tc.respond_to?(:result) ? tc.result : (tc[:result] || tc['result'])
            source    = tc.respond_to?(:source) ? tc.source : (tc[:source] || tc['source'])
            { id: id, name: name, arguments: arguments, result: result, server_tool: server_tool_source?(source) }
          end
        end

        def server_tool_source?(source)
          return false if source.nil?

          type = source.is_a?(Hash) ? (source[:type] || source['type']) : source
          %i[special registry extension mcp].include?(type&.to_sym)
        end

        def extract_fallback_text(final_response)
          msg = final_response.respond_to?(:message) ? final_response.message : nil
          extract_content_text(msg).strip
        end

        def extract_thinking_payload(final_response)
          thinking = final_response.respond_to?(:thinking) ? final_response.thinking : nil
          return nil if thinking.nil?

          if thinking.is_a?(Hash)
            content = thinking[:content] || thinking['content'] || thinking[:text] || thinking['text']
            signature = thinking[:signature] || thinking['signature']
          elsif thinking.respond_to?(:content)
            content = thinking.content
            signature = thinking.respond_to?(:signature) ? thinking.signature : nil
          else
            content = thinking.to_s
            signature = nil
          end
          { content: content.to_s, signature: signature.to_s }
        end

        def final_response_stop_reason(final_response, tool_calls)
          return :tool_use if tool_calls.any? { |tc| !tc[:server_tool] && tc[:result].nil? }
          return :pause_turn if tool_calls.any? { |tc| tc[:server_tool] && tc[:result].nil? }

          stop = final_response.respond_to?(:stop) ? final_response.stop : nil
          reason = stop.is_a?(Hash) ? (stop[:reason] || stop['reason']) : nil
          reason ? reason.to_sym : :end_turn
        end

        def final_response_usage(final_response)
          tokens = final_response.respond_to?(:tokens) ? final_response.tokens : nil
          {
            input_tokens:  token_value(tokens, :input, :input_tokens) || @input_tokens,
            output_tokens: token_value(tokens, :output, :output_tokens) || 0
          }
        end

        def token_value(tokens, *keys)
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

        def resolved_model(final_response)
          routing = final_response.respond_to?(:routing) ? final_response.routing || {} : {}
          (routing[:model] || routing['model'] || @model).to_s
        end

        def serialize_args(args)
          return args.to_s if args.is_a?(String)

          Legion::JSON.dump(args || {})
        rescue StandardError
          args.to_s
        end

        def serialize_result(result)
          return result if result.is_a?(String)

          Legion::JSON.dump(result)
        rescue StandardError
          result.to_s
        end

        # Tiny per-chunk normalizer so the assembler doesn't branch on
        # canonical-vs-legacy chunk shapes.
        AdaptedChunk = ::Struct.new(:text, :thinking_text, :thinking_signature, :tool_calls, keyword_init: true) do
          def initialize(**kwargs)
            kwargs[:tool_calls] ||= []
            super
          end
        end
        private_constant :AdaptedChunk

        module ChunkAdapter
          module_function

          def normalize(chunk)
            return nil if chunk.nil?

            return from_canonical(chunk) if defined?(::Legion::Extensions::Llm::Canonical::Chunk) &&
                                            chunk.is_a?(::Legion::Extensions::Llm::Canonical::Chunk)

            from_legacy(chunk)
          end

          # A canonical chunk delta is normally a String, but a non-incremental
          # final message can arrive as a Canonical::ContentBlock (or array of
          # them). Unwrap to text — never `.to_s` a value object onto the wire.
          def delta_text(delta)
            return '' if delta.nil?
            return delta if delta.is_a?(String)
            return delta.map { |part| delta_text(part) }.join if delta.is_a?(Array)
            return delta.text.to_s if delta.respond_to?(:text) && delta.text
            return delta.content.to_s if delta.respond_to?(:content) && delta.content

            ''
          end

          def from_canonical(chunk)
            case chunk.type
            when :text_delta
              AdaptedChunk.new(text: delta_text(chunk.delta))
            when :thinking_delta
              AdaptedChunk.new(thinking_text: delta_text(chunk.delta), thinking_signature: chunk.signature)
            when :tool_call_delta
              tc = chunk.tool_call
              return AdaptedChunk.new if tc.nil?

              source = tc.respond_to?(:source) ? tc.source : nil
              AdaptedChunk.new(
                tool_calls: [{
                  id:          tc.respond_to?(:id) ? tc.id : nil,
                  name:        tc.respond_to?(:name) ? tc.name : nil,
                  arguments:   tc.respond_to?(:arguments) ? tc.arguments : {},
                  result:      tc.respond_to?(:result) ? tc.result : nil,
                  server_tool: server_tool_source?(source)
                }]
              )
            else
              AdaptedChunk.new
            end
          end

          # Legacy lex-llm Responses::StreamChunk shape (.content, .thinking).
          # NB: legacy chunks in Anthropic/Chat lanes are text-only — the
          # executor tool loop accumulates tool calls into the final response,
          # not per-chunk. The Responses lane uses canonical chunks already.
          # Only probe tool_calls when the chunk is the concrete StreamChunk.
          def from_legacy(chunk)
            text = chunk.respond_to?(:content) ? safe_call(chunk, :content).to_s : chunk.to_s
            thinking_text, thinking_signature = legacy_thinking(chunk)
            AdaptedChunk.new(
              text:               text,
              thinking_text:      thinking_text,
              thinking_signature: thinking_signature,
              tool_calls:         legacy_tool_calls_if_real(chunk)
            )
          end

          def legacy_tool_calls_if_real(chunk)
            return [] unless defined?(::Legion::Extensions::Llm::Responses::StreamChunk) &&
                             chunk.is_a?(::Legion::Extensions::Llm::Responses::StreamChunk)

            legacy_tool_calls(chunk)
          end

          # respond_to? alone isn't sufficient for RSpec doubles that stub
          # respond_to? to true but don't actually implement every getter.
          # RSpec::Mocks::MockExpectationError descends from Exception (not
          # StandardError), so we widen the rescue here just for the adapter
          # entry point.
          def safe_call(obj, method)
            obj.public_send(method)
          rescue Exception # rubocop:disable Lint/RescueException -- isolating provider chunk shape probing
            nil
          end

          def legacy_thinking(chunk)
            return [nil, nil] unless chunk.respond_to?(:thinking)

            thinking = safe_call(chunk, :thinking)
            return [nil, nil] if thinking.nil?

            if thinking.is_a?(Hash)
              normalized = thinking.transform_keys { |k| k.respond_to?(:to_sym) ? k.to_sym : k }
              [normalized[:content] || normalized[:text] || normalized[:thinking], normalized[:signature]]
            elsif thinking.respond_to?(:content) && thinking.content
              [thinking.content, thinking.respond_to?(:signature) ? thinking.signature : nil]
            elsif thinking.respond_to?(:text)
              # Legacy lex-llm Thinking exposes #text/#signature (no #content) —
              # extract the text, never the Ruby `#<...Thinking:0x...>` inspect.
              [thinking.text, thinking.respond_to?(:signature) ? thinking.signature : nil]
            else
              [thinking.is_a?(String) ? thinking : nil, nil]
            end
          end

          def legacy_tool_calls(chunk)
            return [] unless chunk.respond_to?(:tool_calls)

            calls = safe_call(chunk, :tool_calls)
            return [] if calls.nil? || (calls.respond_to?(:empty?) && calls.empty?)

            # Legacy yields tool_calls as { id => obj }. Canonical post-P3 yields arrays.
            iterable = calls.is_a?(Hash) ? calls.values : Array(calls)
            iterable.filter_map do |tc|
              name = tc.respond_to?(:name) ? tc.name.to_s : ''
              args = tc.respond_to?(:arguments) ? tc.arguments : {}
              next if name.empty? && (args.nil? || (args.respond_to?(:empty?) && args.empty?))

              {
                id:          tc.respond_to?(:id) ? tc.id : nil,
                name:        name,
                arguments:   args.is_a?(String) ? safe_parse_args(args) : args,
                server_tool: false
              }
            end
          end

          def safe_parse_args(str)
            return {} if str.to_s.empty?

            Legion::JSON.parse(str, symbolize_names: true)
          rescue StandardError
            str
          end

          def server_tool_source?(source)
            return false if source.nil?

            type = source.is_a?(Hash) ? (source[:type] || source['type']) : source
            %i[special registry extension mcp].include?(type&.to_sym)
          end
        end
      end
    end
  end
end
