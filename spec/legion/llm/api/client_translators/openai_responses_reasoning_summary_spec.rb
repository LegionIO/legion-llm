# frozen_string_literal: true

# Regression test for B3 (P5-final-cells.md): codex→openai /v1/responses cell
# returned no reasoning item because OpenAI's Responses API omits reasoning
# summary content unless the request opts in via `reasoning.summary`. The
# translator now defaults `reasoning.summary` to `'auto'` when the caller
# asked for reasoning (effort set) but didn't pin a summary mode.

require 'spec_helper'
require 'legion/llm/api/client_translators/openai_responses'

RSpec.describe Legion::LLM::API::ClientTranslators::OpenAIResponses, '#ensure_reasoning_summary' do
  subject(:translator) { described_class.new }

  it 'adds summary: "auto" when reasoning.effort is set without a summary' do
    body = { reasoning: { effort: 'medium' } }
    result = translator.ensure_reasoning_summary(body)
    expect(result[:reasoning]).to eq(effort: 'medium', summary: 'auto')
  end

  it 'preserves an explicit summary value' do
    body = { reasoning: { effort: 'high', summary: 'detailed' } }
    result = translator.ensure_reasoning_summary(body)
    expect(result[:reasoning][:summary]).to eq('detailed')
  end

  it 'normalises string keys before checking' do
    body = { reasoning: { 'effort' => 'low', 'summary' => 'concise' } }
    result = translator.ensure_reasoning_summary(body)
    expect(result[:reasoning][:summary]).to eq('concise')
  end

  it 'leaves the body untouched when reasoning is absent' do
    body = { input: 'hello' }
    expect(translator.ensure_reasoning_summary(body)).to eq(body)
  end

  it 'leaves the body untouched when reasoning has no effort' do
    body = { reasoning: { other: 'value' } }
    result = translator.ensure_reasoning_summary(body)
    expect(result[:reasoning]).to eq(other: 'value')
  end

  it 'returns a new hash and does not mutate the input' do
    body = { reasoning: { effort: 'medium' } }
    translator.ensure_reasoning_summary(body)
    expect(body[:reasoning]).to eq(effort: 'medium')
  end
end
