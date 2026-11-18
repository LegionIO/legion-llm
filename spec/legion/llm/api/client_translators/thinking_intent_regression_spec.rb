# frozen_string_literal: true

require 'spec_helper'
require 'legion/llm/api/client_translators/anthropic_messages'
require 'legion/llm/api/client_translators/openai_responses'

RSpec.describe 'Thinking intent across client and inference boundaries' do
  def thinking_requests(budget:)
    anthropic = Legion::LLM::API::ClientTranslators::AnthropicMessages.new
    responses = Legion::LLM::API::ClientTranslators::OpenAIResponses.new
    [
      [anthropic, { model: 'test-model', max_tokens: 32_768,
                    messages: [{ role: 'user', content: 'What is 17 * 23?' }],
                    thinking: { type: 'enabled', budget_tokens: budget } }],
      [responses, { model: 'test-model', max_output_tokens: 32_768,
                    input: [{ role: 'user', content: 'What is 17 * 23?' }],
                    reasoning: { effort: 'high' } }]
    ].map do |translator, payload|
      request = translator.parse_request(payload, {})
      restored = Legion::Extensions::Llm::Canonical::Request.from_hash(
        Legion::JSON.load(Legion::JSON.dump(request.to_h))
      )
      translator.build_inference_request(restored, request_id: 'thinking-intent', server_caller: { source: 'test' })
    end
  end

  it 'does not equate a 2048-token budget with high effort after transport and inference construction' do
    anthropic, responses = thinking_requests(budget: 2048)

    expect(anthropic.thinking.resolved_budget).to eq(2048)
    expect(anthropic.thinking.resolved_effort).to eq('medium')
    expect(responses.thinking.resolved_budget).to eq(16_384)
    expect(responses.thinking.resolved_effort).to eq('high')
    expect(anthropic.thinking.to_h).not_to have_key(:effort)
    expect(responses.thinking.to_h).not_to have_key(:budget)
  end

  it 'resolves equivalent caller constraints consistently without rewriting their supplied axes' do
    anthropic, responses = thinking_requests(budget: 16_384)
    resolved = [anthropic, responses].map do |request|
      [request.thinking.resolved_budget, request.thinking.resolved_effort]
    end

    expect(resolved).to eq([[16_384, 'high'], [16_384, 'high']])
    expect(anthropic.thinking.to_h).to include(budget: 16_384)
    expect(anthropic.thinking.to_h).not_to have_key(:effort)
    expect(responses.thinking.to_h).to include(effort: 'high')
    expect(responses.thinking.to_h).not_to have_key(:budget)
  end
end
