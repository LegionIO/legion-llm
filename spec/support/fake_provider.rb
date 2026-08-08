# frozen_string_literal: true

require 'securerandom'
require 'legion/extensions/llm'
require 'legion/llm/call/registry'
require 'legion/llm/errors'

# Deterministic in-process LLM provider for the matrix harness (G23).
#
# Registered into Legion::LLM::Call::Registry as :fake. Tests select scenarios
# via a thread-local (FakeProvider.with_scenario { ... }) or, for ergonomics
# inside Rack::Test specs, by including the marker `[fake:<scenario>]` anywhere
# in a user message (last user message wins).
#
# The provider implements the same surface as a real lex-llm-* extension:
#   * chat(model:, messages:, **)
#   * stream(model:, messages:, **, &block)
#   * responses(body:, messages:, stream:, **, &block)
#   * embed(model:, text:, **)
#   * count_tokens(model:, messages:, **)
#   * supports?(capability)
#
# Each call returns a Canonical::Response or yields Canonical::Chunks built
# from the named fixture, with no I/O of any kind.
module FakeProvider
  Canonical = Legion::Extensions::Llm::Canonical

  SCENARIOS = %i[
    text
    thinking
    tool_single
    tool_parallel_same_name
    multi_turn_continuation
    stream_text
    stream_thinking
    stream_tool
    server_tool_legion
    server_tool_failure_with_client_passthrough
    tool_degraded_args
    tool_leaked_token
    error
  ].freeze

  SCENARIO_PATTERN = /\[fake:([a-z_]+)\]/

  class << self
    # Register the provider into Call::Registry. Idempotent.
    def register!
      Legion::LLM::Call::Registry.register(
        :fake,
        adapter,
        instance: :default,
        metadata: {
          tier:                  :local,
          capabilities:          %i[chat stream responses embed count_tokens],
          default_model:         'fake-default',
          context_length:        128_000,
          parameter_count_b:     7,
          canonical_model_alias: 'fake-default'
        }
      )
    end

    # Run a block with a forced scenario. Callable from RSpec specs to make the
    # scenario explicit at the call site instead of relying on payload markers.
    def with_scenario(name)
      previous = Thread.current[:fake_provider_scenario]
      Thread.current[:fake_provider_scenario] = name.to_sym
      yield
    ensure
      Thread.current[:fake_provider_scenario] = previous
    end

    # Resolve the active scenario: thread-local first, then payload marker.
    def resolve_scenario(messages)
      forced = Thread.current[:fake_provider_scenario]
      return forced if forced

      Array(messages).reverse_each do |msg|
        text = extract_message_text(msg)
        next if text.nil?

        match = text.match(SCENARIO_PATTERN)
        return match[1].to_sym if match
      end
      :text
    end

    # The adapter object lex-llm extensions register as the "extension_module".
    # Anonymous module so re-loading the spec file doesn't redefine constants.
    def adapter
      @adapter ||= build_adapter
    end

    # Reset cached state. Spec helpers call this in before(:each) to make sure
    # one test's scenario doesn't bleed into another.
    def reset!
      Thread.current[:fake_provider_scenario] = nil
      Thread.current[:fake_provider_calls] = nil
    end

    # G24 step 5: record every chat/responses dispatch so specs can assert
    # the executor's follow-up turn carried the server tool's result back to
    # the provider. Returns an Array of { messages:, model:, kind: } hashes
    # in invocation order.
    def calls
      Thread.current[:fake_provider_calls] ||= []
    end

    def record_call(kind:, model:, messages:, tool_prefs: nil, tools: nil, temperature: nil)
      calls << {
        kind:        kind,
        model:       model,
        messages:    deep_dup(messages),
        tool_prefs:  deep_dup(tool_prefs),
        tools:       deep_dup(tools),
        temperature: temperature
      }
    end

    def deep_dup(value)
      ::Marshal.load(::Marshal.dump(value))
    rescue StandardError
      value
    end

    private

    def extract_message_text(msg)
      return nil unless msg.is_a?(Hash)

      content = msg[:content] || msg['content']
      return content if content.is_a?(String)
      return nil unless content.is_a?(Array)

      content.filter_map do |block|
        next unless block.is_a?(Hash)

        type = (block[:type] || block['type']).to_s
        next unless %w[text input_text].include?(type)

        block[:text] || block['text']
      end.join("\n")
    end

    def build_adapter
      mod = Module.new
      ext = Fixtures
      mod.define_singleton_method(:supports?) do |capability|
        %i[chat stream responses embed count_tokens].include?(capability.to_sym)
      end
      mod.define_singleton_method(:chat) do |model:, messages:, **opts|
        FakeProvider.record_call(kind: :chat, model: model, messages: messages,
                                 tool_prefs: opts[:tool_prefs], tools: opts[:tools],
                                 temperature: opts[:temperature])
        scenario = FakeProvider.resolve_scenario(messages)
        ext.chat_response(scenario, model: model, messages: messages)
      end
      mod.define_singleton_method(:stream) do |model:, messages:, **opts, &block|
        FakeProvider.record_call(kind: :stream, model: model, messages: messages,
                                 tool_prefs: opts[:tool_prefs], tools: opts[:tools],
                                 temperature: opts[:temperature])
        scenario = FakeProvider.resolve_scenario(messages)
        ext.stream_response(scenario, model: model, messages: messages, &block)
      end
      mod.define_singleton_method(:responses) do |body:, messages:, stream:, **opts, &block|
        FakeProvider.record_call(kind: :responses, model: body[:model] || body['model'],
                                 messages: messages, tool_prefs: opts[:tool_prefs], tools: opts[:tools],
                                 temperature: opts[:temperature])
        scenario = FakeProvider.resolve_scenario(messages)
        if stream
          ext.stream_response(scenario, model: body[:model] || body['model'], messages: messages, &block)
        else
          ext.chat_response(scenario, model: body[:model] || body['model'], messages: messages)
        end
      end
      mod.define_singleton_method(:embed) do |model:, text:, **|
        ext.embed_response(model: model, text: text)
      end
      mod.define_singleton_method(:count_tokens) do |model:, messages:, **|
        _ = model
        chars = Array(messages).sum { |m| (m[:content] || m['content']).to_s.length }
        { input_tokens: (chars / 4.0).ceil, model: model }
      end
      mod
    end
  end

  # Pure-data fixture builders. Each scenario returns Canonical types or yields
  # canonical chunks. No I/O. No Time.now divergence — timestamps are :frozen.
  module Fixtures
    Canonical = Legion::Extensions::Llm::Canonical
    FROZEN_TIME = Time.utc(2026, 6, 12, 0, 0, 0).freeze

    module_function

    def chat_response(scenario, model:, messages:)
      raise FakeProvider::Error, 'fake provider error' if scenario == :error

      # Non-stream callers passing a stream-shaped scenario name collapse to
      # the deterministic text response so the matrix can probe both shapes
      # against the same scenario name without a separate switch.
      case scenario
      when :thinking                then thinking_response(model)
      when :tool_single             then tool_single_response(model)
      when :tool_parallel_same_name then tool_parallel_response(model)
      when :multi_turn_continuation then multi_turn_response(model, messages)
      when :server_tool_legion      then server_tool_legion_response(model)
      when :server_tool_failure_with_client_passthrough
        server_tool_failure_with_client_passthrough_response(model)
      when :tool_degraded_args then tool_degraded_args_response(model)
      when :tool_leaked_token  then tool_leaked_token_response(model)
      else text_response(model)
      end
    end

    def stream_response(scenario, model:, messages:, &)
      raise FakeProvider::Error, 'fake provider error' if scenario == :error

      _ = messages
      case scenario
      when :stream_thinking, :thinking then stream_thinking(model, &)
      when :stream_tool, :tool_single  then stream_tool(model, &)
      when :multi_turn_continuation    then stream_text(model, prefix: 'turn-2 ', &)
      else
        stream_text(model, &)
      end
    end

    def embed_response(model:, text:)
      vector = Array.new(8) { |i| ((text.to_s.bytes.sum + i) % 7) / 7.0 }
      {
        result: [vector],
        usage:  { input_tokens: (text.to_s.length / 4) + 1, output_tokens: 0 },
        model:  model
      }
    end

    def text_response(model)
      Canonical::Response.build(
        text:        'Hello there.',
        usage:       usage(input: 4, output: 3),
        stop_reason: :end_turn,
        model:       model.to_s,
        metadata:    { fake: true, scenario: :text }
      )
    end

    def thinking_response(model)
      Canonical::Response.build(
        text:        'Two plus two is four.',
        thinking:    Canonical::Thinking.new(
          content:   'Add 2 and 2. The sum is 4.',
          signature: 'sig_fake_abc123'
        ),
        usage:       usage(input: 6, output: 8, thinking: 5),
        stop_reason: :end_turn,
        model:       model.to_s,
        metadata:    { fake: true, scenario: :thinking }
      )
    end

    def tool_single_response(model)
      Canonical::Response.build(
        text:        '',
        tool_calls:  [tool_call(name: 'bash', args: { command: 'ls -la' }, id: 'call_fake_1')],
        usage:       usage(input: 5, output: 4),
        stop_reason: :tool_use,
        model:       model.to_s,
        metadata:    { fake: true, scenario: :tool_single }
      )
    end

    # Degraded-args scenario: a non-Hash arguments value (e.g. a numeric or a
    # raw string) — the shape live qwen3.6-27b emits when its tool-use markup
    # falls back to plain content. Anthropic tool_use.input MUST still be an
    # object; OpenAI function_call.arguments MUST still be a JSON string. The
    # matrix oracle (P6F2) asserts both.
    def tool_degraded_args_response(model)
      Canonical::Response.build(
        text:        '',
        tool_calls:  [tool_call(name: 'bash', args: 1.01, id: 'call_fake_degraded')],
        usage:       usage(input: 5, output: 4),
        stop_reason: :tool_use,
        model:       model.to_s,
        metadata:    { fake: true, scenario: :tool_degraded_args }
      )
    end

    # Leaked chat-template token scenario: the model emits tool-call intent as a
    # raw <|tool_call>call:NAME{...}<tool_call|> token in CONTENT with EMPTY
    # tool_calls (the exact shape captured live from gemma/vLLM, ledger 2026-07).
    # The executor's native_tool_loop must synthesize this into a structured
    # call (pattern 4) and never surface the raw token to the client. Names the
    # registered fake_legion_echo tool so the synthesized call executes
    # server-side, proving the full round-trip.
    def tool_leaked_token_response(model)
      Thread.current[:fake_leaked_token_round] ||= 0
      Thread.current[:fake_leaked_token_round] += 1

      if Thread.current[:fake_leaked_token_round] == 1
        Canonical::Response.build(
          text:        '<|tool_call>call:fake_legion_echo{value:<|"|>ping<|"|>}<tool_call|>',
          tool_calls:  [],
          usage:       usage(input: 5, output: 4),
          stop_reason: :end_turn,
          model:       model.to_s,
          metadata:    { fake: true, scenario: :tool_leaked_token, round: 1 }
        )
      else
        Thread.current[:fake_leaked_token_round] = 0
        Canonical::Response.build(
          text:        'tool result observed: echo:ping',
          usage:       usage(input: 8, output: 5),
          stop_reason: :end_turn,
          model:       model.to_s,
          metadata:    { fake: true, scenario: :tool_leaked_token, round: 2 }
        )
      end
    end

    def tool_parallel_response(model)
      Canonical::Response.build(
        text:        '',
        tool_calls:  [
          tool_call(name: 'bash', args: { command: 'ls' }, id: 'call_fake_a'),
          tool_call(name: 'bash', args: { command: 'pwd' }, id: 'call_fake_b')
        ],
        usage:       usage(input: 7, output: 6),
        stop_reason: :tool_use,
        model:       model.to_s,
        metadata:    { fake: true, scenario: :tool_parallel_same_name }
      )
    end

    def multi_turn_response(model, messages)
      tool_messages = Array(messages).count { |m| (m[:role] || m['role']).to_s == 'tool' }
      text = tool_messages.positive? ? 'Files listed.' : 'Hello there.'
      Canonical::Response.build(
        text:        text,
        usage:       usage(input: 5, output: 3),
        stop_reason: :end_turn,
        model:       model.to_s,
        metadata:    { fake: true, scenario: :multi_turn_continuation, tool_messages: tool_messages }
      )
    end

    # Server-tool scenario: the provider emits a tool_use for a registered
    # LegionIO tool. The native_tool_loop is expected to execute it server-side
    # and the second-round response is plain text.
    def server_tool_legion_response(model)
      Thread.current[:fake_server_tool_round] ||= 0
      Thread.current[:fake_server_tool_round] += 1

      if Thread.current[:fake_server_tool_round] == 1
        Canonical::Response.build(
          text:        '',
          tool_calls:  [tool_call(name: 'fake_legion_echo', args: { value: 'ping' }, id: 'call_fake_legion')],
          usage:       usage(input: 5, output: 3),
          stop_reason: :tool_use,
          model:       model.to_s,
          metadata:    { fake: true, scenario: :server_tool_legion, round: 1 }
        )
      else
        Thread.current[:fake_server_tool_round] = 0
        Canonical::Response.build(
          text:        'tool result observed: ping',
          usage:       usage(input: 8, output: 5),
          stop_reason: :end_turn,
          model:       model.to_s,
          metadata:    { fake: true, scenario: :server_tool_legion, round: 2 }
        )
      end
    end

    # Regression shape from Codex/vLLM live failure:
    # one LegionIO-executed tool plus one client passthrough tool in the same
    # provider response. When the LegionIO tool result is attached, the executor
    # must update the immutable canonical ToolCall without Hash mutation.
    def server_tool_failure_with_client_passthrough_response(model)
      Canonical::Response.build(
        text:        '',
        tool_calls:  [
          tool_call(name: 'fake_legion_failure', args: {}, id: 'call_fake_legion_bad'),
          tool_call(name: 'exec_command', args: { cmd: 'pwd' }, id: 'call_fake_client_exec')
        ],
        usage:       usage(input: 9, output: 4),
        stop_reason: :tool_use,
        model:       model.to_s,
        metadata:    { fake: true, scenario: :server_tool_failure_with_client_passthrough }
      )
    end

    def stream_text(model, prefix: '')
      request_id = "fake_#{SecureRandom.hex(4)}"
      yield Canonical::Chunk.text_delta(delta: "#{prefix}Hello", request_id: request_id, block_index: 0, item_id: 'msg_fake')
      yield Canonical::Chunk.text_delta(delta: ' there.', request_id: request_id, block_index: 0, item_id: 'msg_fake')
      yield Canonical::Chunk.done(
        request_id:  request_id,
        usage:       usage(input: 4, output: 3),
        stop_reason: :end_turn
      )
      Canonical::Response.build(
        text:        "#{prefix}Hello there.",
        usage:       usage(input: 4, output: 3),
        stop_reason: :end_turn,
        model:       model.to_s,
        metadata:    { fake: true, scenario: :stream_text }
      )
    end

    def stream_thinking(model)
      request_id = "fake_#{SecureRandom.hex(4)}"
      yield Canonical::Chunk.thinking_delta(delta: 'Add 2', request_id: request_id, block_index: 0, signature: 'sig_fake')
      yield Canonical::Chunk.thinking_delta(delta: ' and 2.', request_id: request_id, block_index: 0, signature: 'sig_fake')
      yield Canonical::Chunk.text_delta(delta: 'The answer is 4.', request_id: request_id, block_index: 1, item_id: 'msg_fake')
      yield Canonical::Chunk.done(
        request_id:  request_id,
        usage:       usage(input: 6, output: 8, thinking: 5),
        stop_reason: :end_turn
      )
      Canonical::Response.build(
        text:        'The answer is 4.',
        thinking:    Canonical::Thinking.new(content: 'Add 2 and 2.', signature: 'sig_fake'),
        usage:       usage(input: 6, output: 8, thinking: 5),
        stop_reason: :end_turn,
        model:       model.to_s,
        metadata:    { fake: true, scenario: :stream_thinking }
      )
    end

    def stream_tool(model)
      request_id = "fake_#{SecureRandom.hex(4)}"
      tc = tool_call(name: 'bash', args: { command: 'ls -la' }, id: 'call_fake_stream')
      partial = Canonical::ToolCall.new(
        id:                           tc.id,
        exchange_id:                  nil,
        name:                         'bash',
        arguments:                    { command: 'ls' },
        source:                       { type: :client },
        status:                       :in_progress,
        duration_ms:                  nil,
        result:                       nil,
        error:                        nil,
        started_at:                   nil,
        finished_at:                  nil,
        category:                     nil,
        data_handling_classification: nil,
        policy_decision:              nil
      )
      yield Canonical::Chunk.tool_call_delta(tool_call: partial, request_id: request_id, block_index: 0, item_id: tc.id)
      yield Canonical::Chunk.tool_call_delta(tool_call: tc, request_id: request_id, block_index: 0, item_id: tc.id)
      yield Canonical::Chunk.done(
        request_id:  request_id,
        usage:       usage(input: 5, output: 4),
        stop_reason: :tool_use
      )
      Canonical::Response.build(
        text:        '',
        tool_calls:  [tc],
        usage:       usage(input: 5, output: 4),
        stop_reason: :tool_use,
        model:       model.to_s,
        metadata:    { fake: true, scenario: :stream_tool }
      )
    end

    def tool_call(name:, args:, id:)
      Canonical::ToolCall.new(
        id:                           id,
        exchange_id:                  nil,
        name:                         name,
        arguments:                    args,
        source:                       { type: :client },
        status:                       nil,
        duration_ms:                  nil,
        result:                       nil,
        error:                        nil,
        started_at:                   FROZEN_TIME,
        finished_at:                  nil,
        category:                     nil,
        data_handling_classification: nil,
        policy_decision:              nil
      )
    end

    def usage(input:, output:, thinking: 0)
      Canonical::Usage.new(
        input_tokens:       input,
        output_tokens:      output,
        cache_read_tokens:  0,
        cache_write_tokens: 0,
        thinking_tokens:    thinking,
        units:              {}
      )
    end
  end

  # Provider-side error to exercise the executor's error mapping into
  # client-format errors. Inherits from ProviderError so the namespace
  # routes' rescue chain produces the right HTTP status (502/500).
  class Error < Legion::LLM::ProviderError; end
end
