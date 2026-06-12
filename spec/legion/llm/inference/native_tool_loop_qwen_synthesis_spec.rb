# frozen_string_literal: true

require 'spec_helper'
require 'legion/llm/inference/native_tool_loop'

# Failing-test for the legionio-e2e codex/vllm tool_call regression.
# vLLM/qwen3.6-27b emits tool calls as plain text using a tag-based markup
# template instead of structured tool_calls in the response object:
#
#   <tool_use_name>bash</tool_use_name>
#   <tool_use_parameter>command</tool_use_parameter>
#   <tool_use_value>ls -la</tool_use_value>
#
# Recorded from
#   legionio-e2e/results/codex/vllm_tool_call_returns_valid_tool_calls_response_response.json
#
# The native tool loop's synthesizer only recognized JSON-string arguments
# (text starting with `{"`) under a forced tool choice. Without forced
# choice it didn't synthesize at all, and the qwen markup format wasn't
# recognized — the response shipped back as plain text and the
# CodexValidate.validate_responses_tool_calls assertion failed with
# 0 function_call items vs the expected 1.
#
# After the fix, the synthesizer recognizes the qwen markup, picks the
# tool name from <tool_use_name>, and assembles the
# <tool_use_parameter>/<tool_use_value> pairs into a structured arguments
# hash. The forced-choice JSON path is unchanged.
RSpec.describe 'NativeToolLoop qwen markup tool synthesis' do
  let(:host_class) do
    Class.new do
      include Legion::Logging::Helper
      include Legion::LLM::Inference::NativeToolLoop

      attr_accessor :native_tool_prefs_value, :native_dispatch_tools_value

      def native_tool_prefs = @native_tool_prefs_value
      def native_dispatch_tools = @native_dispatch_tools_value || {}

      # Expose the otherwise-private synthesizer for direct testing.
      public :maybe_synthesize_tool_call_from_content
    end
  end

  let(:host) do
    instance = host_class.new
    instance.native_tool_prefs_value = nil
    instance.native_dispatch_tools_value = { bash: true }
    instance
  end

  let(:qwen_markup) do
    '<tool_use_name>bash</tool_use_name>' \
      '<tool_use_parameter>command</tool_use_parameter>' \
      '<tool_use_value>ls -la</tool_use_value>' \
      '<tool_use_parameter>description</tool_use_parameter>' \
      '<tool_use_value>List files</tool_use_value>'
  end

  def canonical_response_with(text)
    canonical = Legion::Extensions::Llm::Canonical
    canonical::Response.build(
      text:        text,
      usage:       canonical::Usage.new(input_tokens: 1, output_tokens: 1, cache_read_tokens: 0,
                                        cache_write_tokens: 0, thinking_tokens: 0, units: {}),
      stop_reason: :end_turn,
      model:       'qwen3.6-27b',
      metadata:    {}
    )
  end

  it 'synthesizes a structured tool call from qwen <tool_use_name> markup without forced choice' do
    result = canonical_response_with(qwen_markup)

    synthesized = host.maybe_synthesize_tool_call_from_content(result, 0)

    expect(synthesized.size).to eq(1)
    expect(synthesized.first[:name]).to eq('bash')
    expect(synthesized.first[:arguments]).to eq('command' => 'ls -la', 'description' => 'List files')
    expect(synthesized.first[:id]).to start_with('call_')
  end

  it 'preserves forced-choice JSON synthesis (regression guard)' do
    host.native_tool_prefs_value = { choice: :bash }
    result = canonical_response_with('{"command":"ls -la"}')

    synthesized = host.maybe_synthesize_tool_call_from_content(result, 0)

    expect(synthesized.size).to eq(1)
    expect(synthesized.first[:name]).to eq('bash')
    expect(synthesized.first[:arguments]).to eq('command' => 'ls -la')
  end

  it 'returns [] when no tool prefs and no qwen markup match' do
    result = canonical_response_with('Just plain text response.')

    synthesized = host.maybe_synthesize_tool_call_from_content(result, 0)

    expect(synthesized).to eq([])
  end

  it 'returns [] when qwen markup names a tool that is not in native_dispatch_tools' do
    host.native_dispatch_tools_value = { other_tool: true }
    result = canonical_response_with(qwen_markup)

    synthesized = host.maybe_synthesize_tool_call_from_content(result, 0)

    expect(synthesized).to eq([])
  end
end
