# frozen_string_literal: true

require 'spec_helper'
require 'legion/llm/call/embeddings'

# SSOT v3 §21: embeddings select one exact lane via Router.next_lane and dispatch
# the offering's exact callable. Prefix injection is provider-neutral (keyed by
# the SELECTED model). These specs publish embed offerings into the Phase 1
# Registry and assert the exact text the provider callable receives.
RSpec.describe Legion::LLM::Call::Embeddings, :ssot_v3 do
  let(:seed) { 'ab' * 16 }

  before { Legion::LLM.instance_variable_set(:@started, true) }
  after  { Legion::LLM.instance_variable_set(:@started, nil) }

  # Publish an embed offering whose callable records every dispatched embed
  # argument and echoes one 1024-d vector per input. Returns the capture buffer.
  def publish_embed(model:, provider: 'ollama', instance: 'primary', tier: :local, dims: [1024], context: 200_000)
    captured = []
    callable = SsotV3SnapshotFactory::FactoryCallable.new(responder: lambda do |_op, _args, kwargs, _block|
      captured << kwargs
      texts = kwargs[:text]
      vectors = texts.is_a?(Array) ? texts.map { Array.new(1024, 0.1) } : [Array.new(1024, 0.1)]
      { embedding: vectors, usage: { input_tokens: 5 } }
    end)
    activate(
      provider_family: provider, instance_id: instance, callable: callable,
      drafts: [offering_draft(model: model, tier: tier, supported: %i[embed],
                              capabilities: { embedding: :supported },
                              embedding_dimensions: dims, context: context)]
    )
    captured
  end

  describe 'PREFIX_REGISTRY constant' do
    let(:registry) { described_class::PREFIX_REGISTRY }

    it 'maps nomic-embed-text to document and query prefixes' do
      expect(registry['nomic-embed-text']).to include(document: 'search_document: ', query: 'search_query: ')
    end

    it 'maps mxbai-embed-large to a query prefix only' do
      expect(registry['mxbai-embed-large']).to include(query: 'Represent this sentence for searching relevant passages: ')
      expect(registry['mxbai-embed-large'].key?(:document)).to be false
    end
  end

  describe '.generate with prefix injection' do
    context 'with nomic-embed-text model' do
      it 'prepends document prefix by default' do
        captured = publish_embed(model: 'nomic-embed-text')
        described_class.generate(text: 'hello', model: 'nomic-embed-text', routing_seed: seed)
        expect(captured.last[:text]).to eq('search_document: hello')
      end

      it 'prepends document prefix when task: :document' do
        captured = publish_embed(model: 'nomic-embed-text')
        described_class.generate(text: 'hello', model: 'nomic-embed-text', task: :document, routing_seed: seed)
        expect(captured.last[:text]).to eq('search_document: hello')
      end

      it 'prepends query prefix when task: :query' do
        captured = publish_embed(model: 'nomic-embed-text')
        described_class.generate(text: 'hello', model: 'nomic-embed-text', task: :query, routing_seed: seed)
        expect(captured.last[:text]).to eq('search_query: hello')
      end
    end

    context 'with mxbai-embed-large model' do
      it 'prepends query prefix when task: :query' do
        captured = publish_embed(model: 'mxbai-embed-large')
        described_class.generate(text: 'hello', model: 'mxbai-embed-large', task: :query, routing_seed: seed)
        expect(captured.last[:text]).to eq('Represent this sentence for searching relevant passages: hello')
      end

      it 'returns text unchanged for document task (no document prefix defined)' do
        captured = publish_embed(model: 'mxbai-embed-large')
        described_class.generate(text: 'hello', model: 'mxbai-embed-large', task: :document, routing_seed: seed)
        expect(captured.last[:text]).to eq('hello')
      end
    end

    context 'with model variants using a tag suffix' do
      it 'strips the :latest tag and still applies the prefix' do
        captured = publish_embed(model: 'nomic-embed-text:latest')
        described_class.generate(text: 'hello', model: 'nomic-embed-text:latest', task: :document, routing_seed: seed)
        expect(captured.last[:text]).to eq('search_document: hello')
      end
    end

    context 'with an unknown model' do
      it 'returns text unchanged' do
        captured = publish_embed(model: 'unknown-model')
        described_class.generate(text: 'hello world', model: 'unknown-model', routing_seed: seed)
        expect(captured.last[:text]).to eq('hello world')
      end
    end

    context 'when task defaults to :document' do
      it 'uses :document when task is not specified' do
        captured = publish_embed(model: 'nomic-embed-text')
        described_class.generate(text: 'test', model: 'nomic-embed-text', routing_seed: seed)
        expect(captured.last[:text]).to eq('search_document: test')
      end
    end
  end

  describe '.generate_batch with prefix injection' do
    it 'applies the document prefix to every text in the batch (one exact lane)' do
      captured = publish_embed(model: 'nomic-embed-text')
      described_class.generate_batch(texts: %w[foo bar], model: 'nomic-embed-text', task: :document, routing_seed: seed)
      expect(captured.last[:text]).to eq(['search_document: foo', 'search_document: bar'])
    end

    it 'applies the query prefix to every text in the batch' do
      captured = publish_embed(model: 'nomic-embed-text')
      described_class.generate_batch(texts: %w[foo bar], model: 'nomic-embed-text', task: :query, routing_seed: seed)
      expect(captured.last[:text]).to eq(['search_query: foo', 'search_query: bar'])
    end

    it 'passes texts unchanged for an unknown model' do
      captured = publish_embed(model: 'unknown-model')
      described_class.generate_batch(texts: %w[foo bar], model: 'unknown-model', routing_seed: seed)
      expect(captured.last[:text]).to eq(%w[foo bar])
    end
  end
end
