# frozen_string_literal: true

require 'spec_helper'

RSpec.describe 'Legion::LLM error hierarchy' do
  describe Legion::LLM::AuthError do
    it 'is a StandardError' do
      expect(described_class.new('bad creds')).to be_a(StandardError)
    end

    it 'is not retryable' do
      expect(described_class.new('bad creds')).not_to be_retryable
    end
  end

  describe Legion::LLM::RateLimitError do
    it 'is retryable' do
      expect(described_class.new('slow down')).to be_retryable
    end

    it 'carries retry_after' do
      err = described_class.new('slow down', retry_after: 30)
      expect(err.retry_after).to eq(30)
    end
  end

  describe Legion::LLM::ContextOverflow do
    it 'is retryable' do
      expect(described_class.new('too long')).to be_retryable
    end
  end

  describe Legion::LLM::ProviderError do
    it 'is retryable (transient)' do
      expect(described_class.new('500')).to be_retryable
    end
  end

  describe Legion::LLM::ProviderDown do
    it 'is not retryable (circuit breaker)' do
      expect(described_class.new('circuit open')).not_to be_retryable
    end
  end

  describe Legion::LLM::ModelNotAllowed do
    it 'is not retryable (terminal policy outcome)' do
      expect(described_class.new(provider: :bedrock, model: 'anthropic.claude-sonnet-4-6')).not_to be_retryable
    end

    it 'carries the provider and model and a descriptive message' do
      err = described_class.new(provider: :bedrock, model: 'anthropic.claude-sonnet-4-6')
      expect([err.provider, err.model]).to eq([:bedrock, 'anthropic.claude-sonnet-4-6'])
      expect(err.message).to include('not permitted', 'bedrock')
    end
  end

  describe Legion::LLM::UnsupportedCapability do
    it 'is not retryable' do
      expect(described_class.new('no vision')).not_to be_retryable
    end
  end

  describe Legion::LLM::RoutingUnavailable do
    it 'is retryable' do
      expect(described_class.new).to be_retryable
    end

    it 'carries reasons through the kwarg' do
      reasons = [{ provider: :vllm, instance: :h200, model: 'qwen', reason: :circuit_open }]
      expect(described_class.new(reasons: reasons).reasons).to eq(reasons)
    end
  end

  describe Legion::LLM::RoutingTooEarly do
    it 'is retryable' do
      expect(described_class.new).to be_retryable
    end

    it 'carries reasons through the kwarg' do
      reasons = [{ provider: :vllm, reason: :discovery_unavailable }]
      err = described_class.new(reasons: reasons)
      expect(err.reasons).to eq(reasons)
      expect(err.status_code).to eq(425)
    end
  end

  describe Legion::LLM::RoutingFailedDependency do
    it 'is not retryable' do
      expect(described_class.new).not_to be_retryable
    end

    it 'carries reasons through the kwarg' do
      reasons = [{ provider: :bedrock, reason: :model_denied }]
      err = described_class.new(reasons: reasons)
      expect(err.reasons).to eq(reasons)
      expect(err.status_code).to eq(424)
    end
  end

  describe Legion::LLM::InferenceError do
    it 'wraps a step name' do
      err = described_class.new('boom', step: :routing)
      expect(err.step).to eq(:routing)
      expect(err.message).to eq('boom')
    end
  end
end
