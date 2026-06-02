# frozen_string_literal: true

require 'spec_helper'

# Stub response classes for fleet dispatch tests (lex-llm Responses module not auto-loaded in legion-llm)
unless defined?(Legion::Extensions::Llm::Responses::ChatResponse)
  module Legion
    module Extensions
      module Llm
        module Responses
          ChatResponse = Struct.new(:content, :model, keyword_init: true)
          EmbeddingResponse = Struct.new(:vectors, :model, keyword_init: true)
        end
      end
    end
  end
end

RSpec.describe Legion::LLM::Fleet::WorkerExecution do
  let(:envelope) do
    {
      protocol_version:  2,
      request_id:        'req-worker',
      correlation_id:    'corr-worker',
      idempotency_key:   'idem-worker',
      operation:         :chat,
      provider:          'ollama',
      provider_instance: 'default',
      model:             'llama3.2',
      params:            { messages: [{ role: 'user', content: 'hello' }] },
      reply_to:          'llm.fleet.reply.test',
      message_context:   { conversation_id: 'conv-1' },
      signed_token:      'signed-token'
    }
  end

  let(:provider) { instance_double('Provider') }

  before do
    Legion::Settings[:llm][:fleet] = { responder: { require_auth: false } }
    described_class.reset_idempotency_cache!
  end

  it 'validates identity, policy, idempotency, then dispatches the local provider' do
    order = []
    allow(described_class).to receive(:validate_identity!) { order << :identity }
    allow(described_class).to receive(:validate_policy!) { order << :policy }
    allow(described_class).to receive(:validate_idempotency!) { order << :idempotency }
    allow(provider).to receive(:chat) do |messages:, model:, **_opts|
      order << :dispatch
      expect(messages).to eq([{ role: 'user', content: 'hello' }])
      expect(model).to eq('llama3.2')
      Legion::Extensions::Llm::Responses::ChatResponse.new(content: 'done', model: model)
    end

    result = described_class.call(envelope: envelope, provider: provider)

    expect(order).to eq(%i[identity policy idempotency dispatch])
    expect(result.content).to eq('done')
  end

  it 'fails closed when responder auth is required and token validation fails' do
    Legion::Settings[:llm][:fleet] = { responder: { require_auth: true } }
    allow(Legion::LLM::Fleet::TokenValidator).to receive(:validate!)
      .and_raise(Legion::LLM::Fleet::TokenError, 'bad token')

    expect do
      described_class.call(envelope: envelope, provider: provider)
    end.to raise_error(Legion::LLM::Fleet::WorkerExecution::PolicyError, /bad token/)
  end

  it 'rejects duplicate idempotency keys' do
    allow(provider).to receive(:chat).and_return(
      Legion::Extensions::Llm::Responses::ChatResponse.new(content: 'done', model: 'llama3.2')
    )

    described_class.call(envelope: envelope, provider: provider)

    expect do
      described_class.call(envelope: envelope, provider: provider)
    end.to raise_error(Legion::LLM::Fleet::WorkerExecution::PolicyError, /duplicate/)
  end

  it 'atomically reserves idempotency keys before provider dispatch' do
    described_class.reserve_idempotency_key!('idem-worker')

    expect do
      described_class.reserve_idempotency_key!('idem-worker')
    end.to raise_error(Legion::LLM::Fleet::WorkerExecution::PolicyError, /duplicate/)
  end

  it 'allows request with warning when policy enforcement is required but no engine is configured' do
    Legion::Settings[:llm][:fleet] = { responder: { require_auth: false, require_policy: true } }
    allow(provider).to receive(:chat).and_return(
      Legion::Extensions::Llm::Responses::ChatResponse.new(content: 'done', model: 'llama3.2')
    )

    result = described_class.call(envelope: envelope, provider: provider)

    expect(result.content).to eq('done')
  end

  it 'does not burn token replay protection when provider dispatch fails before retry' do
    Legion::Settings[:llm][:fleet] = { responder: { require_auth: true } }
    calls = 0
    allow(Legion::LLM::Fleet::TokenValidator).to receive(:validate!)
      .with(token: 'signed-token', envelope: envelope)
      .and_return({ jti: 'jti-retry' })
    allow(Legion::LLM::Fleet::TokenValidator).to receive(:mark_replay!)
    allow(Legion::LLM::Fleet::TokenValidator).to receive(:release_replay!)
    allow(provider).to receive(:chat) do
      calls += 1
      raise 'transient' if calls == 1

      Legion::Extensions::Llm::Responses::ChatResponse.new(content: 'done', model: 'llama3.2')
    end

    expect do
      described_class.call(envelope: envelope, provider: provider)
    end.to raise_error(RuntimeError, /transient/)

    result = described_class.call(envelope: envelope, provider: provider)

    expect(result.content).to eq('done')
    expect(Legion::LLM::Fleet::TokenValidator).to have_received(:release_replay!).with('jti-retry').once
    expect(Legion::LLM::Fleet::TokenValidator).to have_received(:mark_replay!).with('jti-retry').once
    expect(provider).to have_received(:chat).twice
  end

  it 'dispatches embedding requests with the canonical provider embed contract' do
    embed_envelope = envelope.merge(operation: :embed, params: { text: 'hello', dimensions: 128 })
    allow(provider).to receive(:embed).with(text: 'hello', model: 'llama3.2', dimensions: 128).and_return(
      Legion::Extensions::Llm::Responses::EmbeddingResponse.new(vectors: [[0.1]], model: 'llama3.2')
    )

    result = described_class.call(envelope: embed_envelope, provider: provider)

    expect(result.vectors).to eq([[0.1]])
  end
end
