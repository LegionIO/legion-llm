# frozen_string_literal: true

require 'spec_helper'

RSpec.describe 'RAG fallback and GAIA audit isolation' do
  before do
    Legion::Settings.merge_settings('llm', Legion::LLM::Settings.default)
    Legion::Settings[:llm][:pipeline_enabled] = true
    Legion::Settings[:llm][:default_model] = 'test-model'
    Legion::Settings[:llm][:default_provider] = :test
    allow(Legion::LLM).to receive(:started?).and_return(true)
  end

  it 'degrades gracefully when Apollo is not loaded' do
    hide_const('Legion::Extensions::Apollo') if defined?(Legion::Extensions::Apollo)

    stub_native_provider(content: 'pipeline response')

    request = Legion::LLM::Inference::Request.build(
      messages:         [{ role: :user, content: 'hello' }],
      context_strategy: :rag,
      caller:           { requested_by: { identity: 'user:matt', type: :user } }
    )

    response = Legion::LLM::Inference::Executor.new(request).call

    expect(response).to be_a(Legion::LLM::Inference::Response)
    expect(response.enrichments).not_to have_key('rag:context_retrieval')
    expect(response.warnings).to include(match(/Apollo unavailable/))
  end

  it 'GAIA profile skips post_response audit (no feedback loop)' do
    stub_native_provider(content: 'pipeline response')

    expect(Legion::LLM::Inference::AuditPublisher).not_to receive(:publish)

    request = Legion::LLM::Inference::Request.build(
      messages: [{ role: :user, content: 'synthesize this' }],
      caller:   {
        requested_by: { identity: 'gaia:tick:gas_comprehend', type: :system, credential: :internal }
      }
    )

    response = Legion::LLM::Inference::Executor.new(request).call
    expect(response).to be_a(Legion::LLM::Inference::Response)
  end
end
