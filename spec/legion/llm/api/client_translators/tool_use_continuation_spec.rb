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
      assistant = inf.messages.find { |m| m.role == :assistant }
      expect(assistant).not_to be_nil
      expect(assistant.tool_calls).to be_an(Array)
      expect(assistant.tool_calls.first.name).to eq('legion_list_all_tools')
    end
  end

  # Dead-stop root cause (2026-08-04, captured live): Codex/Responses orders an
  # assistant turn's items as function_call(s) → assistant `message` (text) →
  # function_call_output(s). The translator flushed the tool_calls on the text
  # item then emitted the text as a SEPARATE assistant message, producing:
  #   assistant(tool_calls) → assistant(text) → tool → tool
  # i.e. TWO consecutive assistant messages with the narration wedged between a
  # tool_call and its result. Thinking-enabled open-weight models fed this
  # malformed history narrate their next step instead of calling the tool and
  # end the turn cleanly (finish_reason=stop, no tool call) — the "dead stop".
  # These specs pin the ONE-assistant-turn shape from the captured input verbatim.
  describe Legion::LLM::API::ClientTranslators::OpenAIResponses do
    let(:translator) { described_class.new }

    # Verbatim item ordering from the captured dead-stop request
    # (log_examples/codex_019fcb3e…): two parallel calls, then the assistant's
    # narration text, then the two outputs.
    let(:body) do
      {
        model: 'gemma-4-31b-it',
        input: [
          { role: 'user', content: 'analyze the log' },
          { type: 'function_call', call_id: 'call_A', name: 'exec_command', arguments: '{"command":"head -1 f"}' },
          { type: 'function_call', call_id: 'call_B', name: 'exec_command', arguments: '{"command":"tail -1 f"}' },
          { role: 'assistant', content: "\n\nLet me examine the log structure first:" },
          { type: 'function_call_output', call_id: 'call_A', output: 'line one' },
          { type: 'function_call_output', call_id: 'call_B', output: 'line last' }
        ]
      }
    end

    it 'merges the assistant text-after-calls into ONE assistant turn (no split)' do
      req = translator.parse_request(body, {})
      roles = req.messages.map(&:role)
      # exactly one assistant message; never two in a row
      consecutive_assistant = roles.each_cons(2).count { |a, b| a == :assistant && b == :assistant }
      expect(consecutive_assistant).to eq(0)
      expect(roles.count(:assistant)).to eq(1)
    end

    it 'keeps tool results adjacent to their tool_calls message' do
      req = translator.parse_request(body, {})
      roles = req.messages.map(&:role)
      # user → assistant(text+2 tool_calls) → tool → tool
      expect(roles).to eq(%i[user assistant tool tool])
    end

    it 'carries both the narration text AND both tool_calls on the single assistant turn' do
      req = translator.parse_request(body, {})
      assistant = req.messages.find { |m| m.role == :assistant }
      expect(assistant.tool_calls.map(&:id)).to eq(%w[call_A call_B])
      expect(assistant.content.to_s).to include('Let me examine the log structure first')
    end
  end
end
