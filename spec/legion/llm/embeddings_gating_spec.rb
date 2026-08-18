# frozen_string_literal: true

require 'spec_helper'
require 'legion/llm/call/embeddings'

# SSOT v3 §21: there is no provider "gating" from settings anymore. Eligibility is
# decided entirely by Router.next_lane over the published Registry. An omitted
# model is an UNCONSTRAINED selection (not a default). When nothing eligible
# exists, or every attempt fails, the caller receives a typed RoutingRejected —
# never a nil/zero-vector/safe hash.
RSpec.describe Legion::LLM::Call::Embeddings, :ssot_v3 do
  let(:seed) { 'cd' * 16 }

  before { Legion::LLM.instance_variable_set(:@started, true) }
  after  { Legion::LLM.instance_variable_set(:@started, nil) }

  def publish_embed(model: 'text-embedding-3-small', provider: 'openai', instance: 'primary',
                    tier: :frontier, dims: [1024], &responder)
    responder ||= lambda do |_op, _args, kwargs, _block|
      texts = kwargs[:text]
      vectors = texts.is_a?(Array) ? texts.map { Array.new(1024, 0.5) } : [Array.new(1024, 0.5)]
      { result: vectors, usage: { input_tokens: 7 } }
    end
    activate(
      provider_family: provider, instance_id: instance,
      callable: SsotV3SnapshotFactory::FactoryCallable.new(responder: responder),
      drafts: [offering_draft(model: model, tier: tier, supported: %i[embed],
                              capabilities: { embedding: :supported },
                              embedding_dimensions: dims, context: 200_000)]
    )
  end

  describe '.generate with no eligible embedding function' do
    it 'raises RoutingRejected(:too_early) on a cold registry (no default is invented)' do
      expect { described_class.generate(text: 'hello', routing_seed: seed) }
        .to raise_error(Legion::LLM::Errors::RoutingRejected) { |e| expect(e.rejection.kind).to eq(:too_early) }
    end

    it 'is an LLMError subclass so existing error boundaries still catch it' do
      expect { described_class.generate(text: 'hello', routing_seed: seed) }
        .to raise_error(Legion::LLM::LLMError)
    end
  end

  describe '.generate when every attempt fails at the provider' do
    before { publish_embed { |*| raise StandardError, 'connection refused' } }

    it 'retries on the same session, consumes the target, and raises RoutingRejected (no safe hash)' do
      expect { described_class.generate(text: 'hello', routing_seed: seed) }
        .to raise_error(Legion::LLM::Errors::RoutingRejected)
    end
  end

  describe '.generate with an eligible embedding function' do
    before { publish_embed }

    it 'selects the lane and returns a vector' do
      result = described_class.generate(text: 'hello', routing_seed: seed)
      expect(result[:vector]).to be_a(Array)
      expect(result[:vector].size).to eq(1024)
      expect(result[:provider]).to eq(:openai)
      expect(result[:error]).to be_nil
    end
  end

  describe '.generate_batch with an eligible embedding function' do
    before { publish_embed }

    it 'returns one vector per input, in order (N -> N)' do
      results = described_class.generate_batch(texts: %w[foo bar baz], routing_seed: seed)
      expect(results.size).to eq(3)
      expect(results.map { |r| r[:index] }).to eq([0, 1, 2])
      expect(results).to all(include(vector: be_a(Array)))
    end
  end

  describe '.generate_batch when every attempt fails at the provider' do
    before { publish_embed { |*| raise StandardError, 'batch dispatch failed' } }

    it 'discards partial vectors and raises RoutingRejected for the whole batch' do
      expect { described_class.generate_batch(texts: %w[foo bar baz], routing_seed: seed) }
        .to raise_error(Legion::LLM::Errors::RoutingRejected)
    end
  end
end
