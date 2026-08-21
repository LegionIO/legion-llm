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

  before { Legion::LLM.instance_variable_set(:@started, true) }
  after  { Legion::LLM.instance_variable_set(:@started, nil) }

  def publish_embed(model: 'text-embedding-3-small', provider: 'openai', instance: 'primary', tier: :frontier)
    callable = SsotV3SnapshotFactory::FactoryCallable.new(responder: lambda do |_op, _a, kwargs, _b|
      vecs = kwargs[:text].is_a?(Array) ? kwargs[:text].map { Array.new(1024, 0.1) } : [Array.new(1024, 0.1)]
      { embedding: vecs, usage: { input_tokens: 5 } }
    end)
    activate(
      provider_family: provider, instance_id: instance, callable: callable,
      drafts: [offering_draft(model: model, tier: tier, supported: %i[embed],
                              capabilities: { embedding: :supported },
                              embedding_dimensions: [1024], context: 200_000)]
    )
    callable
  end

  describe 'select-before-cache ordering' do
    it 'never consults the cache when selection rejects (cold registry)' do
      expect(Legion::LLM::Cache).not_to receive(:get)
      expect { described_class.generate(text: 'hello', routing_seed: seed) }
        .to raise_error(Legion::LLM::Errors::RoutingRejected)
    end
  end

  describe 'cache hit (after a proven selection)' do
    it 'returns the cached vector with cache_hit: true and does not dispatch to the provider' do
      callable = publish_embed
      cached = { vector: [0.9, 0.8, 0.7], model: 'text-embedding-3-small', provider: 'openai', dimensions: 3, tokens: 11 }
      allow(Legion::LLM::Cache).to receive(:get).and_return(cached)
      allow(Legion::LLM::Cache).to receive(:set)

      result = described_class.generate(text: 'hello', model: 'text-embedding-3-small', routing_seed: seed)
      expect(result[:cache_hit]).to be(true)
      expect(result[:vector]).to eq([0.9, 0.8, 0.7])
      expect(result[:provider]).to eq(:openai)
      expect(callable.inference_calls).to eq(0)
    end
  end

  describe 'cache miss' do
    it 'dispatches, then writes the vector under the function-identity key with cache_hit: false' do
      publish_embed
      written = {}
      allow(Legion::LLM::Cache).to receive(:get).and_return(nil)
      allow(Legion::LLM::Cache).to receive(:set) { |k, v, **|
        written[:key] = k
        written[:value] = v
      }

      result = described_class.generate(text: 'hello', model: 'text-embedding-3-small', routing_seed: seed)
      expect(result[:cache_hit]).to be(false)
      expect(written[:value][:vector]).to be_a(Array)
      expect(written[:key]).to start_with('llm:embed:openai:text-embedding-3-small:')
    end
  end

  describe 'key composition' do
    def lookup_key(**)
      keys = []
      allow(Legion::LLM::Cache).to receive(:get) { |k|
        keys << k
        nil
      }
      allow(Legion::LLM::Cache).to receive(:set)
      described_class.generate(routing_seed: seed, **)
      keys.last
    end

    it 'excludes lane_id, tier, and the routing seed' do
      publish_embed
      key = lookup_key(text: 'hello', model: 'text-embedding-3-small', provider: 'openai')
      expect(key).not_to include('lane:')
      expect(key).not_to include('frontier')
      expect(key).not_to include(seed)
    end

    it 'does not share across provider families for the same model + text' do
      publish_embed(model: 'shared-embed', provider: 'openai', instance: 'primary')
      publish_embed(model: 'shared-embed', provider: 'bedrock', instance: 'usw2', tier: :cloud)
      openai_key  = lookup_key(text: 'hello', model: 'shared-embed', provider: 'openai')
      bedrock_key = lookup_key(text: 'hello', model: 'shared-embed', provider: 'bedrock')
      expect(openai_key).not_to eq(bedrock_key)
      expect(openai_key).to include('openai')
      expect(bedrock_key).to include('bedrock')
    end

    it 'does not share across instances when no immutable revision evidence is published' do
      publish_embed(model: 'same-model', provider: 'ollama', instance: 'gpu1', tier: :local)
      publish_embed(model: 'same-model', provider: 'ollama', instance: 'gpu2', tier: :local)
      key1 = lookup_key(text: 'hello', model: 'same-model', provider: 'ollama', instance: 'gpu1')
      key2 = lookup_key(text: 'hello', model: 'same-model', provider: 'ollama', instance: 'gpu2')
      expect(key1).not_to eq(key2)
    end
  end

  describe 'cache disabled' do
    it 'skips the cache lookup entirely and still returns the provider vector' do
      publish_embed
      Legion::Settings[:llm][:embedding][:cache] = { enabled: false, ttl: 86_400, key_prefix: 'llm:embed' }
      expect(Legion::LLM::Cache).not_to receive(:get)
      result = described_class.generate(text: 'hello', model: 'text-embedding-3-small', routing_seed: seed)
      expect(result[:vector]).to be_a(Array)
    end
  end
end
