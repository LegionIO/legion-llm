# frozen_string_literal: true

require 'spec_helper'
require 'legion/llm/inference/embed_pipeline'

RSpec.describe Legion::LLM::Inference::EmbedPipeline do
  let(:successful_result) do
    {
      vector:     [0.1, 0.2, 0.3],
      model:      'mxbai-embed-large',
      provider:   :ollama,
      dimensions: 3,
      tokens:     7,
      chunks:     1
    }
  end

  before do
    Legion::LLM::Cache.instance_variable_set(:@local_cache_connected, nil) if Legion::LLM::Cache.instance_variable_defined?(:@local_cache_connected)
    allow(Legion::LLM::Metering).to receive(:emit).and_return(:published)
    allow(Legion::LLM::Call::Embeddings).to receive(:default_model).and_return('mxbai-embed-large')
  end

  describe '.call — cache miss path' do
    before do
      allow(Legion::LLM::Cache).to receive(:get).and_return(nil)
      allow(Legion::LLM::Cache).to receive(:set).and_return(true)
      allow(Legion::LLM::Call::Embeddings).to receive(:generate).and_return(successful_result)
    end

    it 'returns the same shape Call::Embeddings.generate returns' do
      result = described_class.call(text: 'hello world', model: 'mxbai-embed-large', dimensions: 3)
      expect(result[:vector]).to eq([0.1, 0.2, 0.3])
      expect(result[:dimensions]).to eq(3)
      expect(result[:cache_hit]).to be_nil
    end

    it 'invokes the underlying provider call exactly once' do
      expect(Legion::LLM::Call::Embeddings).to receive(:generate).once.and_return(successful_result)
      described_class.call(text: 'hello world', model: 'mxbai-embed-large', dimensions: 3)
    end

    it 'persists the vector under llm:embed:<model>:<dims>:<sha256>' do
      digest = Digest::SHA256.hexdigest('hello world')
      expected_key = "llm:embed:mxbai-embed-large:3:#{digest}"
      expect(Legion::LLM::Cache).to receive(:set).with(expected_key, kind_of(Hash), ttl: kind_of(Integer))
      described_class.call(text: 'hello world', model: 'mxbai-embed-large', dimensions: 3)
    end

    it 'emits metering with cache_hit: false' do
      expect(Legion::LLM::Metering).to receive(:emit).with(hash_including(cache_hit: false, request_type: 'embedding'))
      described_class.call(text: 'hello world', model: 'mxbai-embed-large', dimensions: 3)
    end
  end

  describe '.call — cache hit path' do
    let(:cached_payload) do
      {
        'vector'     => [0.9, 0.8, 0.7],
        'model'      => 'mxbai-embed-large',
        'provider'   => 'ollama',
        'dimensions' => 3,
        'tokens'     => 11
      }
    end

    before do
      allow(Legion::LLM::Cache).to receive(:get).and_return(cached_payload)
      allow(Legion::LLM::Call::Embeddings).to receive(:generate)
    end

    it 'short-circuits and never calls the provider' do
      expect(Legion::LLM::Call::Embeddings).not_to receive(:generate)
      described_class.call(text: 'hello world', model: 'mxbai-embed-large', dimensions: 3)
    end

    it 'returns the cached vector with cache_hit: true' do
      result = described_class.call(text: 'hello world', model: 'mxbai-embed-large', dimensions: 3)
      expect(result[:cache_hit]).to be(true)
      expect(result[:vector]).to eq([0.9, 0.8, 0.7])
      expect(result[:provider]).to eq(:ollama)
    end

    it 'emits metering with cost_usd: 0 and cache_hit: true' do
      expect(Legion::LLM::Metering).to receive(:emit).with(
        hash_including(cache_hit: true, cost_usd: 0, input_tokens: 0, output_tokens: 0)
      )
      described_class.call(text: 'hello world', model: 'mxbai-embed-large', dimensions: 3)
    end

    it 'looks the cached value up at the canonical key llm:embed:<model>:<dims>:<sha256>' do
      digest = Digest::SHA256.hexdigest('hello world')
      expect(Legion::LLM::Cache).to receive(:get).with("llm:embed:mxbai-embed-large:3:#{digest}").and_return(cached_payload)
      described_class.call(text: 'hello world', model: 'mxbai-embed-large', dimensions: 3)
    end
  end

  describe '.call — cache disabled' do
    before do
      Legion::Settings[:llm][:embedding][:cache] = { enabled: false, ttl: 86_400, key_prefix: 'llm:embed' }
      allow(Legion::LLM::Cache).to receive(:get)
      allow(Legion::LLM::Cache).to receive(:set)
      allow(Legion::LLM::Call::Embeddings).to receive(:generate).and_return(successful_result)
    end

    after do
      Legion::Settings[:llm][:embedding][:cache] = { enabled: true, ttl: 86_400, key_prefix: 'llm:embed' }
    end

    it 'skips cache lookup entirely' do
      expect(Legion::LLM::Cache).not_to receive(:get)
      described_class.call(text: 'hello world', model: 'mxbai-embed-large', dimensions: 3)
    end

    it 'still calls the provider and returns its result' do
      expect(Legion::LLM::Call::Embeddings).to receive(:generate).once.and_return(successful_result)
      result = described_class.call(text: 'hello world', model: 'mxbai-embed-large', dimensions: 3)
      expect(result[:vector]).to eq([0.1, 0.2, 0.3])
    end
  end

  describe '.call — error path' do
    before do
      allow(Legion::LLM::Cache).to receive(:get).and_return(nil)
      allow(Legion::LLM::Call::Embeddings).to receive(:generate).and_raise(StandardError.new('boom'))
    end

    it 'returns an error hash without raising' do
      result = described_class.call(text: 'hello world', model: 'mxbai-embed-large')
      expect(result[:error]).to eq('boom')
      expect(result[:vector]).to be_nil
    end

    it 'does not emit metering for a failed call' do
      expect(Legion::LLM::Metering).not_to receive(:emit)
      described_class.call(text: 'hello world', model: 'mxbai-embed-large')
    end
  end

  describe '.cache_key' do
    it 'uses the configured prefix and includes model + dims + digest' do
      key = described_class.cache_key(model: 'voyage-3', dimensions: 1024, digest: 'abc')
      expect(key).to eq('llm:embed:voyage-3:1024:abc')
    end
  end
end
