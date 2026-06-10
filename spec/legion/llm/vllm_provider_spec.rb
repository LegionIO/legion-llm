# frozen_string_literal: true

require 'spec_helper'
require 'legion/llm/router'

RSpec.describe 'vLLM provider integration' do
  before do
    Legion::LLM::Router.reset!
    allow(Legion::LLM::Router).to receive(:tier_available?).and_return(true)
    allow(Legion::LLM::Discovery).to receive(:model_available?).and_return(true)
    allow(Legion::LLM::Discovery).to receive(:model_size).and_return(nil)
    allow(Legion::LLM::Discovery::System).to receive(:available_memory_mb).and_return(65_536)
  end

  describe 'PROVIDER_TIER' do
    it 'maps vllm to fleet tier' do
      expect(Legion::LLM::Router::PROVIDER_TIER[:vllm]).to eq(:fleet)
    end
  end

  describe 'PROVIDER_ORDER' do
    it 'includes vllm before bedrock' do
      order = Legion::LLM::Router::PROVIDER_ORDER
      expect(order).to include(:vllm)
      expect(order.index(:vllm)).to be < order.index(:bedrock)
    end

    it 'places vllm after ollama' do
      order = Legion::LLM::Router::PROVIDER_ORDER
      expect(order.index(:vllm)).to be > order.index(:ollama)
    end
  end

  describe 'default_provider_for_tier(:fleet)' do
    it 'returns :vllm when vllm is registered' do
      Legion::LLM::Call::Registry.register(:vllm, Module.new, metadata: { default_model: 'qwen3.6-27b' })
      result = Legion::LLM::Router.send(:default_provider_for_tier, :fleet)
      expect(result).to eq(:vllm)
    end

    it 'returns :ollama when vllm is not registered' do
      # Reset registry and register only non-vllm providers to simulate vllm absence
      Legion::LLM::Call::Registry.reset!
      %i[anthropic ollama bedrock openai].each do |p|
        Legion::LLM::Call::Registry.register(p, Module.new)
      end
      result = Legion::LLM::Router.send(:default_provider_for_tier, :fleet)
      expect(result).to eq(:ollama)
    end
  end
end
