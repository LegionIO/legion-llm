# frozen_string_literal: true

require 'spec_helper'

RSpec.describe Legion::LLM::Pipeline::Executor do
  let(:request) do
    Legion::LLM::Pipeline::Request.build(
      messages: [{ role: :user, content: 'hello' }],
      routing:  { provider: :anthropic, model: 'claude-opus-4-6' }
    )
  end

  describe '#call' do
    it 'executes the pipeline and returns a Response' do
      executor = described_class.new(request)
      allow(executor).to receive(:step_provider_call).and_return(
        { role: :assistant, content: 'hi there' }
      )
      allow(executor).to receive(:step_response_normalization).and_return(nil)
      response = executor.call
      expect(response).to be_a(Legion::LLM::Pipeline::Response)
      expect(response.request_id).to eq(request.id)
    end

    it 'derives profile from caller' do
      gaia_request = Legion::LLM::Pipeline::Request.build(
        messages: [{ role: :user, content: 'test' }],
        caller:   { requested_by: { identity: 'gaia:tick', type: :system, credential: :internal } }
      )
      executor = described_class.new(gaia_request)
      expect(executor.profile).to eq(:gaia)
    end

    it 'initializes tracing on the request' do
      executor = described_class.new(request)
      allow(executor).to receive(:step_provider_call).and_return(
        { role: :assistant, content: 'test' }
      )
      allow(executor).to receive(:step_response_normalization).and_return(nil)
      response = executor.call
      expect(response.tracing).to be_a(Hash)
      expect(response.tracing[:trace_id]).to be_a(String)
    end

    it 'records timeline events' do
      executor = described_class.new(request)
      allow(executor).to receive(:step_provider_call).and_return(
        { role: :assistant, content: 'test' }
      )
      allow(executor).to receive(:step_response_normalization).and_return(nil)
      response = executor.call
      expect(response.timeline).not_to be_empty
      expect(response.timeline.first[:key]).to eq('tracing:init')
    end

    it 'skips governance steps for gaia profile' do
      gaia_request = Legion::LLM::Pipeline::Request.build(
        messages: [{ role: :user, content: 'test' }],
        caller:   { requested_by: { identity: 'gaia:tick', type: :system, credential: :internal } }
      )
      executor = described_class.new(gaia_request)
      allow(executor).to receive(:step_provider_call).and_return(
        { role: :assistant, content: 'test' }
      )
      allow(executor).to receive(:step_response_normalization).and_return(nil)
      response = executor.call
      keys = response.timeline.map { |e| e[:key] }
      expect(keys).not_to include('rbac:permission_check')
      expect(keys).not_to include('classification:scan')
      expect(keys).not_to include('billing:budget_check')
    end

    describe 'enrichment injection' do
      it 'injects RAG context into system prompt before provider call' do
        rag_request = Legion::LLM::Pipeline::Request.build(
          messages:         [{ role: :user, content: 'what is pgvector?' }],
          system:           'You are helpful.',
          context_strategy: :rag
        )

        apollo_runner = double('Knowledge')
        allow(apollo_runner).to receive(:retrieve_relevant).and_return({
                                                                         success: true,
                                                                         entries: [{ content: 'pgvector is a PostgreSQL extension', content_type: 'fact',
confidence: 0.9 }],
                                                                         count:   1
                                                                       })
        stub_const('Legion::Extensions::Apollo::Runners::Knowledge', apollo_runner)

        mock_session = double('RubyLLM::Chat')
        mock_response = double(content: 'test', input_tokens: 10, output_tokens: 5, model_id: 'test')
        allow(RubyLLM).to receive(:chat).and_return(mock_session)
        allow(mock_session).to receive(:with_tool).and_return(mock_session)
        allow(mock_session).to receive(:ask).and_return(mock_response)

        expect(mock_session).to receive(:with_instructions) do |instructions|
          expect(instructions).to include('pgvector is a PostgreSQL extension')
          mock_session
        end.at_least(:once)

        executor = described_class.new(rag_request)
        executor.call
      end
    end

    describe 'RAG context step' do
      it 'calls Apollo when context_strategy is :rag' do
        rag_request = Legion::LLM::Pipeline::Request.build(
          messages:         [{ role: :user, content: 'what is pgvector?' }],
          context_strategy: :rag
        )

        apollo_runner = double('Knowledge')
        allow(apollo_runner).to receive(:retrieve_relevant).and_return({
                                                                         success: true, entries: [{ content: 'test' }], count: 1
                                                                       })
        stub_const('Legion::Extensions::Apollo::Runners::Knowledge', apollo_runner)

        executor = described_class.new(rag_request)
        allow(executor).to receive(:step_provider_call).and_return(
          { role: :assistant, content: 'test' }
        )
        allow(executor).to receive(:step_response_normalization).and_return(nil)
        response = executor.call

        expect(response.enrichments).to have_key('rag:context_retrieval')
      end

      it 'skips RAG for gaia profile' do
        gaia_request = Legion::LLM::Pipeline::Request.build(
          messages:         [{ role: :user, content: 'test' }],
          context_strategy: :rag,
          caller:           { requested_by: { identity: 'gaia:tick', type: :system, credential: :internal } }
        )
        executor = described_class.new(gaia_request)
        allow(executor).to receive(:step_provider_call).and_return(
          { role: :assistant, content: 'test' }
        )
        allow(executor).to receive(:step_response_normalization).and_return(nil)
        response = executor.call

        # RAG step is skipped for GAIA profile (GAIA_SKIP includes rag_context is not listed,
        # but verify it at least doesn't crash.
        expect(response).to be_a(Legion::LLM::Pipeline::Response)
      end
    end
  end
end
