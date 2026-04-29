# frozen_string_literal: true

require 'spec_helper'
require 'legion/llm/router'
require 'legion/llm/discovery/vllm'

RSpec.describe 'vLLM provider integration' do
  before do
    Legion::LLM::Router.reset!
    allow(Legion::LLM::Router).to receive(:tier_available?).and_return(true)
    allow(Legion::LLM::Discovery::Ollama).to receive(:model_available?).and_return(true)
    allow(Legion::LLM::Discovery::Ollama).to receive(:model_size).and_return(nil)
    allow(Legion::LLM::Discovery::System).to receive(:available_memory_mb).and_return(65_536)
    allow(Legion::LLM::Discovery::Vllm).to receive(:model_available?).and_return(true)
    allow(Legion::LLM::Discovery::Vllm).to receive(:max_context).and_return(32_768)
  end

  describe 'PROVIDER_TIER' do
    it 'maps vllm to local tier' do
      expect(Legion::LLM::Router::PROVIDER_TIER[:vllm]).to eq(:local)
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
    it 'returns :vllm when vllm is enabled' do
      Legion::Settings[:llm][:providers][:vllm] = { enabled: true, default_model: 'qwen3.6-27b' }
      result = Legion::LLM::Router.send(:default_provider_for_tier, :fleet)
      expect(result).to eq(:vllm)
    end

    it 'returns :ollama when vllm is not enabled' do
      Legion::Settings[:llm][:providers][:vllm] = { enabled: false }
      result = Legion::LLM::Router.send(:default_provider_for_tier, :fleet)
      expect(result).to eq(:ollama)
    end
  end

  describe 'provider configuration' do
    it 'stores vllm base_url and resolved api_key in settings config' do
      config = { base_url: 'http://gpu:8000/v1', api_key: 'test-key' }

      Legion::LLM::Call::Providers.send(:configure_vllm, config)

      expect(config[:base_url]).to eq('http://gpu:8000/v1')
      expect(config[:api_key]).to eq('test-key')
    end

    it 'stores default vllm base_url when absent' do
      config = {}

      Legion::LLM::Call::Providers.send(:configure_vllm, config)

      expect(config[:base_url]).to eq('http://localhost:8000/v1')
    end
  end

  describe '.normalize_vllm_base_url' do
    it 'strips trailing slashes and a v1 suffix without regex backtracking' do
      normalized = Legion::LLM::Call::Providers.send(:normalize_vllm_base_url, 'http://gpu:8000/v1////')

      expect(normalized).to eq('http://gpu:8000')
    end

    it 'keeps non-v1 paths' do
      normalized = Legion::LLM::Call::Providers.send(:normalize_vllm_base_url, 'http://gpu:8000/api////')

      expect(normalized).to eq('http://gpu:8000/api')
    end
  end
end
