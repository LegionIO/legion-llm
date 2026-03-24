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

    describe 'post-response step' do
      it 'publishes audit event for external profile' do
        executor = described_class.new(request)
        allow(executor).to receive(:step_provider_call).and_return(
          { role: :assistant, content: 'test' }
        )
        allow(executor).to receive(:step_response_normalization).and_return(nil)
        expect(Legion::LLM::Pipeline::AuditPublisher).to receive(:publish)
        executor.call
      end

      it 'skips audit publish for gaia profile' do
        gaia_request = Legion::LLM::Pipeline::Request.build(
          messages: [{ role: :user, content: 'test' }],
          caller:   { requested_by: { identity: 'gaia:tick', type: :system, credential: :internal } }
        )
        executor = described_class.new(gaia_request)
        allow(executor).to receive(:step_provider_call).and_return(
          { role: :assistant, content: 'test' }
        )
        allow(executor).to receive(:step_response_normalization).and_return(nil)
        expect(Legion::LLM::Pipeline::AuditPublisher).not_to receive(:publish)
        executor.call
      end
    end

    describe 'GAIA advisory step' do
      it 'includes gaia:advisory in enrichments when GAIA available' do
        gaia_mod = Module.new
        allow(gaia_mod).to receive(:advise).and_return({ valence: [0.5] })
        allow(gaia_mod).to receive(:started?).and_return(true)
        stub_const('Legion::Gaia', gaia_mod)

        executor = described_class.new(request)
        allow(executor).to receive(:step_provider_call).and_return(
          { role: :assistant, content: 'test' }
        )
        allow(executor).to receive(:step_response_normalization).and_return(nil)
        response = executor.call

        expect(response.enrichments).to have_key('gaia:advisory')
      end
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
  end

  describe 'step_context_load' do
    before { Legion::LLM::ConversationStore.reset! }

    it 'loads prior messages into enrichments when conversation_id present' do
      Legion::LLM::ConversationStore.append('conv_123', role: :user, content: 'earlier message')
      Legion::LLM::ConversationStore.append('conv_123', role: :assistant, content: 'earlier reply')

      req = Legion::LLM::Pipeline::Request.build(
        messages:        [{ role: :user, content: 'new question' }],
        conversation_id: 'conv_123',
        routing:         { provider: :anthropic, model: 'claude-opus-4-6' }
      )
      executor = described_class.new(req)
      allow(executor).to receive(:step_provider_call)
      executor.call
      expect(executor.enrichments[:conversation_history]).to be_an(Array)
      expect(executor.enrichments[:conversation_history].size).to eq(2)
    end

    it 'skips when no conversation_id' do
      executor = described_class.new(request)
      allow(executor).to receive(:step_provider_call)
      executor.call
      expect(executor.enrichments[:conversation_history]).to be_nil
    end
  end

  describe 'step_context_store' do
    before { Legion::LLM::ConversationStore.reset! }

    it 'appends request message and response to ConversationStore' do
      req = Legion::LLM::Pipeline::Request.build(
        messages:        [{ role: :user, content: 'hello' }],
        conversation_id: 'conv_store_test',
        routing:         { provider: :anthropic, model: 'claude-opus-4-6' }
      )
      executor = described_class.new(req)

      mock_response = double('response', content: 'hi there', input_tokens: 10, output_tokens: 5)
      allow(RubyLLM).to receive(:chat).and_return(double('session', with_tool: nil, ask: mock_response))
      allow(executor).to receive(:step_response_normalization)

      executor.call

      messages = Legion::LLM::ConversationStore.messages('conv_store_test')
      expect(messages.size).to eq(2)
      expect(messages.first[:role]).to eq(:user)
      expect(messages.last[:role]).to eq(:assistant)
      expect(messages.last[:content]).to eq('hi there')
    end

    it 'skips when no conversation_id' do
      executor = described_class.new(request)
      allow(executor).to receive(:step_provider_call)
      expect(Legion::LLM::ConversationStore).not_to receive(:append)
      executor.call
    end
  end

  describe 'error classification in provider call' do
    it 'wraps RubyLLM 429 as RateLimitError' do
      executor = described_class.new(request)
      allow(RubyLLM).to receive(:chat).and_raise(
        Faraday::TooManyRequestsError.new(nil, { status: 429 })
      )
      expect { executor.call }.to raise_error(Legion::LLM::RateLimitError)
    end

    it 'wraps RubyLLM 401 as AuthError' do
      executor = described_class.new(request)
      allow(RubyLLM).to receive(:chat).and_raise(
        Faraday::UnauthorizedError.new(nil, { status: 401 })
      )
      expect { executor.call }.to raise_error(Legion::LLM::AuthError)
    end

    it 'wraps generic provider errors as ProviderError' do
      executor = described_class.new(request)
      allow(RubyLLM).to receive(:chat).and_raise(
        Faraday::ServerError.new(nil, { status: 500 })
      )
      expect { executor.call }.to raise_error(Legion::LLM::ProviderError)
    end
  end
end
