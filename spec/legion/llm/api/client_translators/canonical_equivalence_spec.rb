# frozen_string_literal: true

require 'spec_helper'
require 'legion/llm/api/client_translators/anthropic_messages'
require 'legion/llm/api/client_translators/openai_responses'

# SSOT / one-oracle: the same logical request must parse to an IDENTICAL
# Canonical::Request regardless of client dialect (Anthropic /v1/messages vs
# OpenAI /v1/responses). Offline mirror of legionio-e2e spec/canonical/*.
#
# Divergences these guard (all were real Responses-translator bugs):
#   - system prompt: Anthropic sets canonical `system:`; Responses injected a
#     role:system MESSAGE instead of populating `system:`.
#   - tool_call with preceding text: Anthropic keeps text + tool_calls in ONE
#     assistant message; Responses split it into two assistant messages.
RSpec.describe 'client translator canonical equivalence' do
  let(:anthropic) { Legion::LLM::API::ClientTranslators::AnthropicMessages.new }
  let(:responses) { Legion::LLM::API::ClientTranslators::OpenAIResponses.new }
  let(:env) { { 'HTTP_X_LEGION_PROVIDER' => 'vllm' } }

  # Compare the routing-relevant canonical shape (messages + system), ignoring
  # per-request generated ids and dialect-specific metadata — same spirit as the
  # e2e strip_generated_ids.
  def canonical_shape(req)
    {
      system:   req.system,
      messages: Array(req.messages).map do |m|
        tcs = Array(m.tool_calls)
        names = tcs.map { |tc| tc.respond_to?(:name) ? tc.name.to_s : (tc[:name] || tc['name']).to_s }
        {
          role:       m.role.to_s,
          content:    m.content,
          tool_calls: names.empty? ? nil : names
        }.compact
      end
    }
  end

  it 'system prompt: both formats put system in canonical `system:`, not a message' do
    anthropic_req = anthropic.parse_request(
      { model: 'gemma-4-31b-it', max_tokens: 128,
        system: 'You are a helpful assistant that always responds in JSON format.',
        messages: [{ role: 'user', content: 'What is 2+2?' }] },
      env
    )
    responses_req = responses.parse_request(
      { model: 'gemma-4-31b-it', max_output_tokens: 128,
        instructions: 'You are a helpful assistant that always responds in JSON format.',
        input: [{ role: 'user', content: 'What is 2+2?' }] },
      env
    )

    expect(canonical_shape(responses_req)).to eq(canonical_shape(anthropic_req))
  end

  it 'tool_call with preceding text: both keep text + tool_calls in ONE assistant message' do
    anthropic_req = anthropic.parse_request(
      { model: 'gemma-4-31b-it', max_tokens: 1024,
        messages: [
          { role: 'user', content: 'What time is it?' },
          { role: 'assistant', content: [
            { type: 'text', text: 'Let me check the current time for you.' },
            { type: 'tool_use', id: 't1', name: 'get_time', input: { timezone: 'UTC' } }
          ] },
          { role: 'user', content: [{ type: 'tool_result', tool_use_id: 't1', content: '2026-06-22T21:50:00Z' }] }
        ] },
      env
    )
    responses_req = responses.parse_request(
      { model: 'gemma-4-31b-it', max_output_tokens: 1024,
        input: [
          { role: 'user', content: 'What time is it?' },
          { type: 'message', role: 'assistant', content: 'Let me check the current time for you.' },
          { type: 'function_call', call_id: 't1', name: 'get_time', arguments: '{"timezone":"UTC"}' },
          { type: 'function_call_output', call_id: 't1', output: '2026-06-22T21:50:00Z' }
        ] },
      env
    )

    expect(canonical_shape(responses_req)).to eq(canonical_shape(anthropic_req))
  end
end
