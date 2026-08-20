# frozen_string_literal: true

require 'spec_helper'
require 'legion/llm/inference/native_tool_loop'

# Regression (2026-08-15 local daemon, SSOT v3): a provider value that is not
# a Canonical::Response must be normalized at the executor's dispatch boundary
# (RouteAttempts#ssot_v3_direct_dispatch → Call::Dispatch.normalize_response)
# before the native tool loop consumes it. Previously a non-canonical value
# reached NativeToolLoop#extract_tool_calls and crashed with
# NoMethodError — a 500 after a successful provider 200.
#
# 0.8.0 (kit B2): conformant callables return Canonical::Response by type, so
# the primary path is pass-through; the raw-Hash normalization stays as the
# boundary for untyped provider values.
RSpec.describe 'Dispatch-boundary response normalization' do
  def provider_response
    Legion::Extensions::Llm::Canonical::Response.build(
      text:        'hello from vllm',
      tool_calls:  [
        Legion::Extensions::Llm::Canonical::ToolCall.build(
          id: 'call_1', name: 'ruby', arguments: { command: 'x' }, source: :client
        )
      ],
      usage:       Legion::Extensions::Llm::Canonical::Usage.build(input_tokens: 100, output_tokens: 12),
      stop_reason: :tool_use,
      model:       'gemma-4-31b-it'
    )
  end

  it 'passes an already-canonical response through unchanged' do
    response = provider_response
    expect(Legion::LLM::Call::Dispatch.normalize_response(response)).to equal(response)
  end

  it 'normalizes a raw provider hash into a Canonical::Response with text, tool calls, usage, and stop reason' do
    raw = {
      content:     'hello from vllm',
      tool_calls:  [{ id: 'call_1', name: 'ruby', arguments: { command: 'x' }, source: 'client' }],
      usage:       { input_tokens: 100, output_tokens: 12 },
      stop_reason: 'tool_use'
    }
    response = Legion::LLM::Call::Dispatch.normalize_response(raw)
    expect(response).to be_a(Legion::Extensions::Llm::Canonical::Response)
    expect(response.text).to eq('hello from vllm')
    expect(response.tool_calls.map(&:name)).to eq(['ruby'])
    expect(response.stop_reason).to eq(:tool_use)
    expect(response.usage.input_tokens).to eq(100)
    expect(response.usage.output_tokens).to eq(12)
  end

  it 'lets NativeToolLoop#extract_tool_calls consume the normalized value (the crash site)' do
    host = Class.new { extend Legion::LLM::Inference::NativeToolLoop }
    normalized = Legion::LLM::Call::Dispatch.normalize_response(provider_response)

    # extract_tool_calls requires BOTH :tool_calls and :text on the value.
    expect(normalized).to respond_to(:tool_calls)
    expect(normalized).to respond_to(:text)
    expect(host.send(:extract_tool_calls, normalized).map(&:name)).to eq(['ruby'])
  end
end
