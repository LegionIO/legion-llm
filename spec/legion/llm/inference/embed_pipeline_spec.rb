# frozen_string_literal: true

require 'spec_helper'
require 'legion/llm/inference/embed_pipeline'

# SSOT v3 §21: EmbedPipeline is a slim governed entry over Call::Embeddings.
# Selection, dispatch, and the content-addressed cache are owned by Call::Embeddings
# (which selects the exact lane BEFORE any cache lookup, per §21.2).
# EmbedPipeline no longer reads cache keys, calls Cache directly, or holds a
# cache_key method. It normalizes the caller input, routes through
# Call::Embeddings.generate, and emits the metering event.
RSpec.describe Legion::LLM::Inference::EmbedPipeline do
  let(:successful_result) do
    {
      vector:     [0.1, 0.2, 0.3],
      model:      'mxbai-embed-large',
      provider:   :ollama,
      dimensions: 3,
      tokens:     7,
      chunks:     1,
      tier:       'local',
      cache_hit:  false
    }
  end

  before do
    allow(Legion::LLM::Metering).to receive(:emit).and_return(:published)
  end

  describe '.call — delegates to Call::Embeddings and emits metering' do
    before do
      allow(Legion::LLM::Call::Embeddings).to receive(:generate).and_return(successful_result)
    end

    it 'returns the same shape Call::Embeddings.generate returns' do
      result = described_class.call(text: 'hello world', model: 'mxbai-embed-large', dimensions: 3)
      expect(result[:vector]).to eq([0.1, 0.2, 0.3])
      expect(result[:dimensions]).to eq(3)
    end

    it 'invokes the underlying provider call exactly once' do
      expect(Legion::LLM::Call::Embeddings).to receive(:generate).once.and_return(successful_result)
      described_class.call(text: 'hello world', model: 'mxbai-embed-large', dimensions: 3)
    end

    it 'emits metering with cache_hit: false' do
      expect(Legion::LLM::Metering).to receive(:emit).with(hash_including(cache_hit: false, request_type: 'embedding'))
      described_class.call(text: 'hello world', model: 'mxbai-embed-large', dimensions: 3)
    end
  end

  # SSOT v3 §21.2: the cache lives inside Call::Embeddings (select -> cache -> dispatch).
  # EmbedPipeline surfaces the cache_hit: true signal from generate's return value
  # and emits the appropriate zero-cost metering event — it never calls Cache directly.
  describe '.call — cache hit path (Call::Embeddings returns cache_hit: true)' do
    let(:cached_result) do
      {
        vector:     [0.9, 0.8, 0.7],
        model:      'mxbai-embed-large',
        provider:   :ollama,
        dimensions: 3,
        tokens:     11,
        chunks:     1,
        tier:       'local',
        cache_hit:  true
      }
    end

    before do
      allow(Legion::LLM::Call::Embeddings).to receive(:generate).and_return(cached_result)
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
  end

  describe '.call — Call::Embeddings always invoked (cache is its responsibility)' do
    before do
      allow(Legion::LLM::Call::Embeddings).to receive(:generate).and_return(successful_result)
    end

    it 'calls the provider and returns its result' do
      expect(Legion::LLM::Call::Embeddings).to receive(:generate).once.and_return(successful_result)
      result = described_class.call(text: 'hello world', model: 'mxbai-embed-large', dimensions: 3)
      expect(result[:vector]).to eq([0.1, 0.2, 0.3])
    end
  end

  # SSOT v3: errors from Call::Embeddings propagate to the caller.
  # LLMErrors are re-raised directly; other StandardErrors are logged then re-raised.
  # EmbedPipeline never swallows an exception or returns an error hash.
  describe '.call — error path' do
    before do
      allow(Legion::LLM::Call::Embeddings).to receive(:generate).and_raise(StandardError.new('boom'))
    end

    it 'propagates the error to the caller (never swallows)' do
      expect { described_class.call(text: 'hello world', model: 'mxbai-embed-large') }
        .to raise_error(StandardError, 'boom')
    end

    it 'does not emit metering for a failed call' do
      expect(Legion::LLM::Metering).not_to receive(:emit)
      expect { described_class.call(text: 'hello world', model: 'mxbai-embed-large') }
        .to raise_error(StandardError)
    end
  end
end
