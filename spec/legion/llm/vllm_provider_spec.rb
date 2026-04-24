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

  describe 'default_model_for_tier(:fleet)' do
    it 'returns vllm default_model when vllm is enabled' do
      Legion::Settings[:llm][:providers][:vllm] = { enabled: true, default_model: 'qwen3.6-27b' }
      result = Legion::LLM::Router.send(:default_model_for_tier, :fleet)
      expect(result).to eq('qwen3.6-27b')
    end
  end

  describe 'settings defaults' do
    it 'includes vllm provider with correct defaults' do
      vllm = Legion::Settings[:llm][:providers][:vllm]
      expect(vllm).to be_a(Hash)
      expect(vllm[:enabled]).to be false
      expect(vllm[:default_model]).to eq('qwen3.6-27b')
      expect(vllm[:base_url]).to eq('http://localhost:8000/v1')
    end
  end

  describe 'provider configuration' do
    let(:ruby_llm_config) { double('config') }

    before do
      allow(RubyLLM).to receive(:configure).and_yield(ruby_llm_config)
      allow(ruby_llm_config).to receive(:vllm_api_base=)
      allow(ruby_llm_config).to receive(:vllm_api_key=)
      hide_const('Legion::Identity::Broker')
    end

    it 'sets vllm_api_base from config' do
      Legion::LLM::Call::Providers.send(:configure_vllm, { base_url: 'http://10.11.164.92:8000/v1' })
      expect(ruby_llm_config).to have_received(:vllm_api_base=).with('http://10.11.164.92:8000/v1')
    end

    it 'sets vllm_api_key when present' do
      Legion::LLM::Call::Providers.send(:configure_vllm, { base_url: 'http://gpu:8000/v1', api_key: 'test-key' })
      expect(ruby_llm_config).to have_received(:vllm_api_key=).with('test-key')
    end

    it 'does not set vllm_api_key when absent' do
      Legion::LLM::Call::Providers.send(:configure_vllm, { base_url: 'http://gpu:8000/v1' })
      expect(ruby_llm_config).not_to have_received(:vllm_api_key=)
    end
  end

  describe 'escalation chain' do
    it 'includes vllm in enabled_provider_chain when enabled' do
      Legion::Settings[:llm][:providers][:vllm] = { enabled: true, default_model: 'qwen3.6-27b' }
      chain = Legion::LLM::Router.send(:enabled_provider_chain)
      providers = chain.map(&:provider)
      expect(providers).to include(:vllm)
    end
  end
end
