# frozen_string_literal: true

require 'spec_helper'
require 'legion/llm/api/client_translators/openai_responses'
require 'legion/llm/api/client_translators/openai_chat'
require 'legion/llm/api/client_translators/anthropic_messages'

# Regression: assistant messages carrying tool_calls were rendered downstream
# in the OpenAI nested shape `{id, type: 'function', function: {name, arguments}}`,
# but Canonical::Message.from_hash forwards each tool_call hash directly to
# ToolCall.from_hash, which expects FLAT keys (`name`, `arguments`). The
# nested-function shape produces ToolCall(name: nil) — provider translators
# then drop the call (no name) and the downstream `tool_result` message has
# no preceding `tool_use` for Bedrock to anchor against → ValidationException.
#
# The fix unwraps the nested {function: {name, arguments}} envelope at the
# client-translator boundary so canonical sees the flat shape.
RSpec.describe 'Client translator multi-turn tool_use continuation' do
  let(:canonical) { Legion::Extensions::Llm::Canonical }

  describe Legion::LLM::API::ClientTranslators::OpenAIResponses do
    let(:translator) { described_class.new }

    # Conformance fixture: Codex-style multi-turn tool_use → tool_result → continuation.
    # Mirrors the legionio_tool_injection turn-2 payload that fails on Bedrock today.
    let(:body) do
      {
        model: 'us.anthropic.claude-sonnet-4-6',
        input: [
          { role: 'user', content: 'How many legionio tools do I have?' },
          { type: 'function_call', call_id: 'call_001', name: 'legion_list_all_tools', arguments: '{}' },
          { type: 'function_call_output', call_id: 'call_001', output: '{"tools":["foo","bar"]}' },
          { role: 'user', content: 'Now summarize them.' }
        ]
      }
    end

    it 'preserves the assistant tool_use message in the canonical request' do
      req = translator.parse_request(body, {})
      assistant_messages = req.messages.select { |m| m.role == :assistant }
      expect(assistant_messages.size).to eq(1)
      assistant = assistant_messages.first
      expect(assistant.tool_calls).to be_an(Array)
      expect(assistant.tool_calls.size).to eq(1)
    end

    it 'unwraps the OpenAI nested {function: {name, arguments}} into flat ToolCall(name:, arguments:)' do
      req = translator.parse_request(body, {})
      tc = req.messages.find { |m| m.role == :assistant }.tool_calls.first
      expect(tc).to be_a(canonical::ToolCall)
      expect(tc.name).to eq('legion_list_all_tools')
      expect(tc.id).to eq('call_001')
      # arguments must be a Hash, not a wire-format function envelope.
      expect(tc.arguments).to eq({})
    end

    it 'orders messages: user → assistant(tool_use) → tool_result → user (continuation)' do
      req = translator.parse_request(body, {})
      roles = req.messages.map(&:role)
      expect(roles).to eq(%i[user assistant tool user])
    end

    it 'links tool_result.tool_call_id to the preceding assistant tool_call.id' do
      req = translator.parse_request(body, {})
      assistant = req.messages.find { |m| m.role == :assistant }
      tool_msg = req.messages.find { |m| m.role == :tool }
      expect(tool_msg.tool_call_id).to eq(assistant.tool_calls.first.id)
    end

    it 'preserves the assistant message through to the inference request (no empty-assistant strip)' do
      req = translator.parse_request(body, {})
      inf = translator.build_inference_request(
        req,
        request_id:    'req_test',
        server_caller: { source: 'test' }
      )
      assistant = inf.messages.find { |m| m[:role] == :assistant }
      expect(assistant).not_to be_nil
      expect(assistant[:tool_calls]).to be_an(Array)
      expect(assistant[:tool_calls].first[:name].to_s).to eq('legion_list_all_tools')
    end
  end
end
