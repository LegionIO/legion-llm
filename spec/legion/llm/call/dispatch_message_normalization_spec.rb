# frozen_string_literal: true

require 'spec_helper'
require 'legion/llm/inference/native_tool_loop'

# Regression (2026-08-15 local daemon, SSOT v3): provider sync/stream callables
# return a lex-llm Message. SelectionDispatch passes the raw callable value
# through, so the executor's dispatch boundary
# (RouteAttempts#ssot_v3_direct_dispatch → Call::Dispatch.normalize_response)
# must restore the pre-SSOT contract (Canonical::Response) before the native
# tool loop consumes it. Previously the raw Message reached
# NativeToolLoop#extract_tool_calls and crashed with
# NoMethodError: undefined method '[]' for an instance of
# Legion::Extensions::Llm::Message — a 500 after a successful provider 200.
RSpec.describe 'Dispatch-boundary Message normalization' do
  def provider_message
    Legion::Extensions::Llm::Message.new(
      role:          :assistant,
      content:       'hello from vllm',
      model_id:      'gemma-4-31b-it',
      tool_calls:    [
        Legion::Extensions::Llm::Canonical::ToolCall.build(
          id: 'call_1', name: 'ruby', arguments: { command: 'x' }, source: :client
        )
      ],
      input_tokens:  100,
      output_tokens: 12,
      stop_reason:   :tool_use
    )
  end

  it 'normalizes a provider Message into a Canonical::Response with text, tool calls, usage, and stop reason' do
    response = Legion::LLM::Call::Dispatch.normalize_response(provider_message)
    expect(response).to be_a(Legion::Extensions::Llm::Canonical::Response)
    expect(response.text).to eq('hello from vllm')
    expect(response.tool_calls.map(&:name)).to eq(['ruby'])
    expect(response.stop_reason).to eq(:tool_use)
    expect(response.usage.input_tokens).to eq(100)
    expect(response.usage.output_tokens).to eq(12)
  end

  it 'passes an already-canonical response through unchanged' do
    canonical = Legion::Extensions::Llm::Canonical::Response.new(
      text: 'x', thinking: nil, tool_calls: [], usage: nil,
      stop_reason: :end_turn, model: 'm', routing: {}, metadata: {}
    )
    expect(Legion::LLM::Call::Dispatch.normalize_response(canonical)).to equal(canonical)
  end

  it 'lets NativeToolLoop#extract_tool_calls consume the normalized value (the crash site)' do
    host = Class.new { extend Legion::LLM::Inference::NativeToolLoop }
    normalized = Legion::LLM::Call::Dispatch.normalize_response(provider_message)

    # extract_tool_calls' duck-type guard requires BOTH :tool_calls and :text.
    # A raw Message satisfies :tool_calls but not :text, so it fell through to
    # result[:tool_calls] and raised NoMethodError. The normalized Response
    # satisfies both.
    expect(normalized).to respond_to(:tool_calls)
    expect(normalized).to respond_to(:text)
    expect(host.send(:extract_tool_calls, normalized).map(&:name)).to eq(['ruby'])
  end
end
