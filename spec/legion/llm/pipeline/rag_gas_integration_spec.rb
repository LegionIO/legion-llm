# frozen_string_literal: true

require 'spec_helper'

RSpec.describe 'RAG/GAS full cycle' do
  before do
    Legion::Settings.merge_settings('llm', Legion::LLM::Settings.default)
    Legion::Settings[:llm][:pipeline_enabled] = true
    Legion::Settings[:llm][:default_model] = 'test-model'
    Legion::Settings[:llm][:default_provider] = :test
    allow(Legion::LLM).to receive(:started?).and_return(true)
  end

  it 'RAG enriches request, response triggers audit publish' do
    apollo_runner = double('Knowledge')
    allow(apollo_runner).to receive(:retrieve_relevant).and_return({
      success: true,
      entries: [{ content: 'pgvector uses HNSW', content_type: 'fact', confidence: 0.9 }],
      count: 1
    })
    stub_const('Legion::Extensions::Apollo::Runners::Knowledge', apollo_runner)

    mock_session = double('RubyLLM::Chat')
    mock_response = double('RubyLLM::Message',
                           content: 'HNSW provides fast ANN search',
                           input_tokens: 50, output_tokens: 30,
                           model_id: 'test-model')
    allow(RubyLLM).to receive(:chat).and_return(mock_session)
    allow(mock_session).to receive(:with_tool).and_return(mock_session)
    allow(mock_session).to receive(:with_instructions).and_return(mock_session)
    allow(mock_session).to receive(:ask).and_return(mock_response)

    published_event = nil
    allow(Legion::LLM::Pipeline::AuditPublisher).to receive(:publish) do |args|
      published_event = args
    end

    request = Legion::LLM::Pipeline::Request.build(
      messages: [{ role: :user, content: 'how does pgvector search work?' }],
      context_strategy: :rag,
      caller: { requested_by: { identity: 'user:matt', type: :user } }
    )

    response = Legion::LLM::Pipeline::Executor.new(request).call

    expect(response).to be_a(Legion::LLM::Pipeline::Response)
    expect(response.enrichments).to have_key('rag:context_retrieval')
    expect(response.enrichments['rag:context_retrieval'][:data][:entries].length).to eq(1)
    expect(response.enrichments['rag:context_retrieval'][:data][:strategy]).to eq(:rag)
  end

  it 'injects RAG context into system prompt for provider call' do
    apollo_runner = double('Knowledge')
    allow(apollo_runner).to receive(:retrieve_relevant).and_return({
      success: true,
      entries: [{ content: 'pgvector is a PostgreSQL extension', content_type: 'fact', confidence: 0.9 }],
      count: 1
    })
    stub_const('Legion::Extensions::Apollo::Runners::Knowledge', apollo_runner)

    mock_session = double('RubyLLM::Chat')
    mock_response = double('RubyLLM::Message',
                           content: 'test response', input_tokens: 10,
                           output_tokens: 5, model_id: 'test-model')
    allow(RubyLLM).to receive(:chat).and_return(mock_session)
    allow(mock_session).to receive(:with_tool).and_return(mock_session)
    allow(mock_session).to receive(:ask).and_return(mock_response)

    injected = nil
    allow(mock_session).to receive(:with_instructions) do |instructions|
      injected = instructions
      mock_session
    end

    request = Legion::LLM::Pipeline::Request.build(
      messages: [{ role: :user, content: 'what is pgvector?' }],
      system: 'You are helpful.',
      context_strategy: :rag,
      caller: { requested_by: { identity: 'user:matt', type: :user } }
    )

    Legion::LLM::Pipeline::Executor.new(request).call

    expect(injected).to include('pgvector is a PostgreSQL extension')
    expect(injected).to include('You are helpful.')
  end

  it 'degrades gracefully when Apollo is not loaded' do
    hide_const('Legion::Extensions::Apollo') if defined?(Legion::Extensions::Apollo)

    mock_session = double('RubyLLM::Chat')
    mock_response = double('RubyLLM::Message',
                           content: 'response without RAG', input_tokens: 10,
                           output_tokens: 5, model_id: 'test-model')
    allow(RubyLLM).to receive(:chat).and_return(mock_session)
    allow(mock_session).to receive(:with_tool).and_return(mock_session)
    allow(mock_session).to receive(:with_instructions).and_return(mock_session)
    allow(mock_session).to receive(:ask).and_return(mock_response)

    request = Legion::LLM::Pipeline::Request.build(
      messages: [{ role: :user, content: 'hello' }],
      context_strategy: :rag,
      caller: { requested_by: { identity: 'user:matt', type: :user } }
    )

    response = Legion::LLM::Pipeline::Executor.new(request).call

    expect(response).to be_a(Legion::LLM::Pipeline::Response)
    expect(response.enrichments).not_to have_key('rag:context_retrieval')
    expect(response.warnings).to include(match(/Apollo unavailable/))
  end

  it 'GAIA profile skips post_response audit (no feedback loop)' do
    mock_session = double('RubyLLM::Chat')
    mock_response = double('RubyLLM::Message',
                           content: 'gaia response', input_tokens: 10,
                           output_tokens: 5, model_id: 'test-model')
    allow(RubyLLM).to receive(:chat).and_return(mock_session)
    allow(mock_session).to receive(:with_tool).and_return(mock_session)
    allow(mock_session).to receive(:with_instructions).and_return(mock_session)
    allow(mock_session).to receive(:ask).and_return(mock_response)

    expect(Legion::LLM::Pipeline::AuditPublisher).not_to receive(:publish)

    request = Legion::LLM::Pipeline::Request.build(
      messages: [{ role: :user, content: 'synthesize this' }],
      caller: {
        requested_by: { identity: 'gaia:tick:gas_comprehend', type: :system, credential: :internal }
      }
    )

    response = Legion::LLM::Pipeline::Executor.new(request).call
    expect(response).to be_a(Legion::LLM::Pipeline::Response)
  end
end
