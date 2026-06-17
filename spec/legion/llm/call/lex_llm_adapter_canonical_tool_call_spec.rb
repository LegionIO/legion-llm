# frozen_string_literal: true

require 'spec_helper'
require 'legion/llm/call/lex_llm_adapter'

# Failing-test for the legionio-e2e claude/bedrock + codex/bedrock + claude/openai
# legionio_tool_injection regression. The executor's native tool loop appends
# an assistant message whose `tool_calls` is an Array of Canonical::ToolCall
# (Data) objects. The LexLLMAdapter must normalize those into
# Legion::Extensions::Llm::ToolCall objects so the downstream provider
# (Bedrock invoke_model_chat / OpenAI chat completions) can render the
# matching tool_use blocks. Without that, the assistant turn ships with NO
# tool_calls — the next tool-role message becomes orphaned and the provider
# rejects with:
#   * Bedrock: "unexpected `tool_use_id` found in `tool_result` blocks: <id>.
#     Each `tool_result` block must have a corresponding `tool_use` block in
#     the previous message."
#   * OpenAI:  "messages with role 'tool' must be a response to a preceeding
#     message with 'tool_calls'."
#
# The bug is in normalize_hash + normalize_message_tool_calls — they assume
# everything responds to transform_keys, which Data structs don't.
RSpec.describe Legion::LLM::Call::LexLLMAdapter, '#normalize_messages with Canonical::ToolCall' do
  let(:canonical) { Legion::Extensions::Llm::Canonical }

  response_stub_class = Struct.new(:content, :model_id, :tool_calls, :usage, :raw, :thinking) do
    def tool_call? = false
  end

  let(:response_stub) { response_stub_class }

  let(:provider_class) do
    stub = response_stub_class
    Class.new do
      define_method(:initialize) { |*| @received_messages = nil }

      attr_reader :received_messages

      define_method(:chat) do |messages:, **|
        @received_messages = messages
        stub.new('ok', 'gpt-test', nil, { input_tokens: 1, output_tokens: 1 }, {}, nil)
      end

      define_method(:stream_chat) do |messages:, **|
        @received_messages = messages
        stub.new('ok', 'gpt-test', nil, { input_tokens: 1, output_tokens: 1 }, {}, nil)
      end
    end
  end

  let(:adapter) do
    described_class.new(:openai, provider_class, instance_config: { api_key: 'test' })
  end

  let(:tool_call) do
    canonical::ToolCall.build(
      id:        'toolu_bdrk_001',
      name:      'legion_list_all_tools',
      arguments: { filter: 'all' },
      source:    { type: :registry }
    )
  end

  # The assistant message produced by Legion::LLM::Inference::Executor#native_assistant_tool_message
  # for round-2 of the tool loop:
  let(:executor_messages) do
    [
      { role: :user, content: 'how many legionio tools do you have available?' },
      { role: :assistant, content: '', tool_calls: [tool_call] },
      { role: :tool, content: 'tools: legion_list_all_tools', tool_call_id: 'toolu_bdrk_001', name: 'legion_list_all_tools' }
    ]
  end

  it 'preserves Canonical::ToolCall.name and id when normalizing the assistant message' do
    normalized = adapter.send(:normalize_messages, executor_messages)
    assistant = normalized.find { |m| m.role == :assistant }

    expect(assistant).not_to be_nil
    expect(assistant.tool_calls).not_to be_nil,
                                        'assistant message must carry the tool_calls; otherwise tool_result becomes orphaned downstream'
    expect(assistant.tool_calls).not_to be_empty,
                                        'tool_calls must NOT be filtered out by normalize_message_tool_calls'

    tcs = assistant.tool_calls.is_a?(Hash) ? assistant.tool_calls.values : Array(assistant.tool_calls)
    expect(tcs.size).to eq(1)
    expect(tcs.first.name).to eq('legion_list_all_tools')
    expect(tcs.first.id).to eq('toolu_bdrk_001')
  end
end
