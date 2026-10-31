# frozen_string_literal: true

require 'spec_helper'
require 'legion/llm/api/client_translators/anthropic_messages'
require 'legion/llm/api/client_translators/openai_responses'
require 'legion/llm/api/client_translators/openai_chat'

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
  let(:chat) { Legion::LLM::API::ClientTranslators::OpenAIChat.new }
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

  it 'preserves exact text and canonical representation across all client dialects and roles' do
    messages = %w[user assistant].map do |role|
      { role: role, content: [{ type: 'text', text: 'hello' }, { type: 'text', text: " world\nnext" }] }
    end
    requests = [
      anthropic.parse_request({ messages: messages }, {}),
      chat.parse_request({ messages: messages }, {}),
      responses.parse_request({ input: messages }, {})
    ]

    expect(requests.map { |request| canonical_shape(request) }.uniq).to eq([
                                                                             { system: nil, messages: [
                                                                               { role: 'user', content: "hello world\nnext" },
                                                                               { role: 'assistant', content: "hello world\nnext" }
                                                                             ] }
                                                                           ])
  end

  it 'preserves annotated text boundaries instead of collapsing cache semantics' do
    blocks = [
      { type: 'text', text: 'before', cache_control: { type: 'ephemeral', ttl: '1h' } },
      { type: 'text', text: ' after' }
    ]
    requests = [
      anthropic.parse_request({ messages: [{ role: 'user', content: blocks }] }, {}),
      chat.parse_request({ messages: [{ role: 'user', content: blocks }] }, {}),
      responses.parse_request({ input: [{ role: 'user', content: blocks }] }, {})
    ]

    expect(requests.map { |request| canonical_shape(request) }.uniq.size).to eq(1)
    expect(requests.first.messages.first.content.map { |block| [block.text, block.cache_control] }).to eq([
                                                                                                            ['before', { type: 'ephemeral', ttl: '1h' }], [' after', nil]
                                                                                                          ])
  end

  it 'does not insert whitespace when flushing text around a tool result' do
    text = [{ type: 'text', text: 'hello' }, { type: 'text', text: ' world' }]
    anthropic_request = anthropic.parse_request(
      { messages: [{ role: 'user', content: text + [
        { type: 'tool_result', tool_use_id: 'call-1', content: text },
        { type: 'text', text: 'continue' }
      ] }] }, {}
    )
    chat_request = chat.parse_request(
      { messages: [
        { role: 'user', content: text },
        { role: 'tool', tool_call_id: 'call-1', content: text },
        { role: 'user', content: 'continue' }
      ] }, {}
    )

    expect(canonical_shape(anthropic_request)).to eq(canonical_shape(chat_request))
    expect(anthropic_request.messages.map(&:text)).to eq(['hello world', 'hello world', 'continue'])
    expect(anthropic_request.messages[1].tool_call_id).to eq('call-1')
  end
end
