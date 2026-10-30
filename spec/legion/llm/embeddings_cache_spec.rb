# frozen_string_literal: true

require 'spec_helper'
require 'legion/llm/call/embeddings'

# M4: the settings-pin → tier-rank → default_model selection domain (and its
# fallback chain / detect_embedding_capability state) is gone — SSOT :embed
# routing is the sole selection authority. What remains of the embedding
# surface here is the function-identity cache contract (§21.2).

# SSOT v3 §21.2: the embedding cache is keyed by embedding-FUNCTION identity, not
# routing-lane identity. Selection happens BEFORE the cache lookup — a hit is only
# served after a current Selection proves the request has an eligible embedding
# function. The key never includes lane_id/offering_id/tier/weight/routing seed.
RSpec.describe Legion::LLM::Call::Embeddings, 'embedding-function cache (§21.2)', :ssot_v3 do
  let(:seed) { '9f' * 16 }

  before do
    Legion::LLM.instance_variable_set(:@started, true)
    @cache = {}
    allow(Legion::LLM::Cache).to receive(:get) { |key| @cache[key] }
    allow(Legion::LLM::Cache).to receive(:set) do |key, value, **|
      @cache[key] = Legion::JSON.load(Legion::JSON.dump(value))
    end
  end
  after { Legion::LLM.instance_variable_set(:@started, nil) }

  def publish_embed(model: 'text-embedding-3-small', provider: 'openai', instance: 'primary', tier: :frontier, revision: nil, **)
    callable = SsotV3SnapshotFactory::FactoryCallable.new(responder: lambda do |_op, _a, kwargs, _b|
      vecs = kwargs[:text].is_a?(Array) ? kwargs[:text].map { Array.new(1024, 0.1) } : [Array.new(1024, 0.1)]
      { embedding: vecs, usage: { input_tokens: 5 } }
    end)
    activate(
      provider_family: provider, instance_id: instance, callable: callable,
      drafts: [offering_draft(model: model, tier: tier, supported: %i[embed],
                              capabilities: { embedding: :supported },
                              embedding_dimensions: [1024], context: 200_000, model_revision: revision)]
    )
    callable
  end

  describe 'select-before-cache ordering' do
    it 'rejects an ineligible request even when its previous embedding is cached' do
      publish_embed
      described_class.generate(text: 'hello', routing_seed: seed)
      Legion::Extensions::Llm::Inventory::Registry.reset!
      expect { described_class.generate(text: 'hello', routing_seed: seed) }
        .to raise_error(Legion::LLM::Errors::RoutingRejected)
    end
  end

  describe 'legacy cache entries' do
    it 'regenerates unprovenanced vectors instead of relabeling them from the current selection' do
      callable = publish_embed
      cached = { vector: [0.9, 0.8, 0.7], model: 'text-embedding-3-small', provider: 'openai', dimensions: 3, tokens: 11 }
      allow(Legion::LLM::Cache).to receive(:get).and_return(cached)
      allow(Legion::LLM::Cache).to receive(:set)

      result = described_class.generate(text: 'hello', model: 'text-embedding-3-small', routing_seed: seed)
      expect(result[:cache_hit]).to be(false)
      expect(result[:vector]).to eq(Array.new(1024, 0.1))
      expect(callable.inference_calls).to eq(1)
      expect(result[:embedding_provenance]).to include(
        provider: 'openai', model: 'text-embedding-3-small', instance: 'primary',
        dimensions: 1024, identity_source: 'instance', model_revision: nil, task: 'document'
      )
    end
  end

  describe 'cached provenance and vector validation' do
    it 'preserves provenance through cache serialization and rebinds the current selected instance' do
      first_callable = publish_embed(instance: 'first', revision: 'same-revision')
      second_callable = publish_embed(instance: 'second', revision: 'same-revision')
      first = described_class.generate(text: 'hello', instance: 'first', routing_seed: seed)
      second = described_class.generate(text: 'hello', instance: 'second', routing_seed: seed)
      expect(first[:cache_hit]).to be(false)
      expect(second[:cache_hit]).to be(true)
      expect(second[:vector]).to eq(first[:vector])
      expect(second[:embedding_provenance]).to eq(first[:embedding_provenance].merge(instance: 'second'))
      expect(second[:instance].to_s).to eq('second')
      expect(first_callable.inference_calls).to eq(1)
      expect(second_callable.inference_calls).to eq(0)
    end

    it 'does not reuse a document cache entry after only the query prefix changes' do
      callable = publish_embed(model: 'nomic-embed-text')
      first = described_class.generate(text: 'hello', routing_seed: seed)
      Legion::Settings[:llm][:embedding][:prefix_registry]['nomic-embed-text'][:query] = 'changed: '
      second = described_class.generate(text: 'hello', routing_seed: seed)
      expect(second[:cache_hit]).to be(false)
      expect(second[:embedding_provenance][:space_id]).not_to eq(first[:embedding_provenance][:space_id])
      expect(callable.inference_calls).to eq(2)
    end

    it 'regenerates malformed cached vectors instead of assigning them provenance' do
      callable = publish_embed
      allow(Legion::LLM::Cache).to receive(:get).and_return(vector: [1.0, Float::NAN], dimensions: 2)
      result = described_class.generate(text: 'hello', routing_seed: seed)
      expect(result[:cache_hit]).to be(false)
      expect(result[:vector]).to eq(Array.new(1024, 0.1))
      expect(callable.inference_calls).to eq(1)
    end

    it 'regenerates cached vectors with dimensions inconsistent with the explicit request' do
      callable = publish_embed
      allow(Legion::LLM::Cache).to receive(:get).and_return(vector: [1.0, 2.0], dimensions: 2)
      result = described_class.generate(text: 'hello', dimensions: 1024, routing_seed: seed)
      expect(result[:cache_hit]).to be(false)
      expect(result[:embedding_provenance][:dimensions]).to eq(1024)
      expect(callable.inference_calls).to eq(1)
    end

    it 'regenerates a cache entry with inconsistent durable space identity' do
      callable = publish_embed
      first = described_class.generate(text: 'hello', routing_seed: seed)
      @cache.values.first[:embedding_provenance][:space_id] = '0' * 64
      second = described_class.generate(text: 'hello', routing_seed: seed)
      expect(second[:cache_hit]).to be(false)
      expect(second[:embedding_provenance]).to eq(first[:embedding_provenance])
      expect(callable.inference_calls).to eq(2)
    end

    it 'regenerates when cached metadata contradicts its retained space ID' do
      callable = publish_embed
      first = described_class.generate(text: 'hello', routing_seed: seed)
      @cache.values.first[:embedding_provenance][:model] = 'different-model'
      second = described_class.generate(text: 'hello', routing_seed: seed)
      expect(second[:cache_hit]).to be(false)
      expect(second[:embedding_provenance]).to eq(first[:embedding_provenance])
      expect(callable.inference_calls).to eq(2)
    end
  end

  describe 'cache isolation' do
    it 'reuses a proven embedding across routing seeds' do
      callable = publish_embed
      first = described_class.generate(text: 'hello', routing_seed: seed)
      second = described_class.generate(text: 'hello', routing_seed: '1a' * 16)
      expect(second[:cache_hit]).to be(true)
      expect(second[:vector]).to eq(first[:vector])
      expect(callable.inference_calls).to eq(1)
    end

    it 'does not share across provider families for the same model and text' do
      first_callable = publish_embed(model: 'shared-embed', provider: 'openai', instance: 'primary')
      second_callable = publish_embed(model: 'shared-embed', provider: 'bedrock', instance: 'usw2', tier: :cloud)
      first = described_class.generate(text: 'hello', model: 'shared-embed', provider: 'openai', routing_seed: seed)
      second = described_class.generate(text: 'hello', model: 'shared-embed', provider: 'bedrock', routing_seed: seed)
      expect(second[:cache_hit]).to be(false)
      expect(second[:embedding_provenance][:space_id]).not_to eq(first[:embedding_provenance][:space_id])
      expect(first_callable.inference_calls).to eq(1)
      expect(second_callable.inference_calls).to eq(1)
    end

    it 'does not share across instances when no immutable revision evidence is published' do
      first_callable = publish_embed(model: 'same-model', provider: 'ollama', instance: 'gpu1', tier: :local)
      second_callable = publish_embed(model: 'same-model', provider: 'ollama', instance: 'gpu2', tier: :local)
      first = described_class.generate(text: 'hello', instance: 'gpu1', routing_seed: seed)
      second = described_class.generate(text: 'hello', instance: 'gpu2', routing_seed: seed)
      expect(second[:cache_hit]).to be(false)
      expect(second[:embedding_provenance][:space_id]).not_to eq(first[:embedding_provenance][:space_id])
      expect(first_callable.inference_calls).to eq(1)
      expect(second_callable.inference_calls).to eq(1)
    end
  end

  describe 'cache disabled' do
    it 'regenerates rather than reusing an already warm cache' do
      callable = publish_embed
      described_class.generate(text: 'hello', routing_seed: seed)
      Legion::Settings[:llm][:embedding][:cache] = { enabled: false, ttl: 86_400, key_prefix: 'llm:embed' }
      result = described_class.generate(text: 'hello', model: 'text-embedding-3-small', routing_seed: seed)
      expect(result[:vector]).to eq(Array.new(1024, 0.1))
      expect(result[:cache_hit]).to be(false)
      expect(callable.inference_calls).to eq(2)
    end
  end
end
