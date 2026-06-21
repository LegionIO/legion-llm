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
end
