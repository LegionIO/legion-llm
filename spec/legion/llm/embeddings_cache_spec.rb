# frozen_string_literal: true

require 'spec_helper'
require 'legion/llm/call/embeddings'

RSpec.describe 'Legion::LLM embedding fallback chain cache' do
  before do
    Legion::LLM::Inventory::Discovery.instance_variable_set(:@can_embed, nil)
    Legion::LLM::Inventory::Discovery.instance_variable_set(:@embedding_provider, nil)
    Legion::LLM::Inventory::Discovery.instance_variable_set(:@embedding_model, nil)
    Legion::LLM::Inventory::Discovery.instance_variable_set(:@embedding_fallback_chain, nil)
  end

  after do
    Legion::LLM::Inventory::Discovery.instance_variable_set(:@embedding_fallback_chain, nil)
  end

  describe 'LLM.embedding_fallback_chain' do
    context 'when detect_embedding_capability finds a provider' do
      before do
        Legion::Settings[:extensions][:llm][:ollama] = { enabled: true, base_url: 'http://localhost:11434' }
        allow(Legion::LLM::Inventory::Discovery).to receive(:model_available?).and_return(false)
        allow(Legion::LLM::Inventory::Discovery).to receive(:model_available?)
          .with('mxbai-embed-large', provider: :ollama).and_return(true)
        allow(Legion::LLM::Inventory::Discovery).to receive(:verify_embedding).and_return(true)
      end

      it 'returns an array after detect_embedding_capability runs' do
        Legion::LLM::Inventory::Discovery.detect_embedding_capability
        expect(Legion::LLM.embedding_fallback_chain).to be_an(Array)
      end

      it 'contains entries with :provider and :model keys' do
        Legion::LLM::Inventory::Discovery.detect_embedding_capability
        chain = Legion::LLM.embedding_fallback_chain
        expect(chain).to all(include(:provider))
      end

      it 'includes the detected provider in the chain' do
        Legion::LLM::Inventory::Discovery.detect_embedding_capability
        providers = Legion::LLM.embedding_fallback_chain.map { |e| e[:provider] }
        expect(providers).to include(:ollama)
      end
    end

    context 'when no provider is available' do
      before do
        allow(Legion::LLM::Inventory::Discovery).to receive(:model_available?).and_return(false)
        Legion::Settings[:extensions][:llm].each_value { |v| v[:enabled] = false }
      end

      it 'returns an empty array' do
        Legion::LLM::Inventory::Discovery.detect_embedding_capability
        expect(Legion::LLM.embedding_fallback_chain).to eq([])
      end
    end

    context 'after shutdown clears the chain' do
      it 'is set to nil by shutdown' do
        Legion::LLM::Inventory::Discovery.instance_variable_set(:@embedding_fallback_chain,
                                                                [{ provider: :ollama, model: 'mxbai-embed-large' }])
        allow(Legion::LLM::Call::Registry).to receive(:reset!)
        Legion::LLM.instance_variable_set(:@started, true)
        # simulate shutdown resetting the chain ivar
        Legion::LLM::Inventory::Discovery.instance_variable_set(:@embedding_fallback_chain, nil)
        expect(Legion::LLM.embedding_fallback_chain).to be_nil
      end
    end
  end

  describe 'LLM.build_embedding_fallback_chain (private)' do
    it 'includes only enabled providers' do
      Legion::Settings[:extensions][:llm][:ollama] = { enabled: true, base_url: 'http://localhost:11434' }
      Legion::Settings[:extensions][:llm][:bedrock] = { enabled: false }
      # General stub (false) must come first; specific stub (true) overrides for the target model
      allow(Legion::LLM::Inventory::Discovery).to receive(:model_available?).and_return(false)
      allow(Legion::LLM::Inventory::Discovery).to receive(:model_available?)
        .with('mxbai-embed-large', provider: :ollama).and_return(true)

      chain = Legion::LLM::Inventory::Discovery.send(:build_embedding_fallback_chain,
                                                     { provider_fallback: %w[ollama bedrock] })
      providers = chain.map { |e| e[:provider] }
      expect(providers).to include(:ollama)
      expect(providers).not_to include(:bedrock)
    end

    it 'returns an empty array when no providers are available' do
      Legion::Settings[:extensions][:llm].each_value { |v| v[:enabled] = false }
      chain = Legion::LLM::Inventory::Discovery.send(:build_embedding_fallback_chain, {})
      expect(chain).to eq([])
    end

    it 'uses model from provider_models when a supported cloud provider is enabled' do
      Legion::Settings[:extensions][:llm][:openai] = { enabled: true, default_model: 'gpt-4o' }
      allow(Legion::LLM::Inventory::Discovery).to receive(:verify_embedding).and_return(true)

      chain = Legion::LLM::Inventory::Discovery.send(:build_embedding_fallback_chain, {
                                                       provider_fallback: %w[openai],
                                                       provider_models:   { 'openai' => 'text-embedding-3-small' }
                                                     })
      entry = chain.find { |e| e[:provider] == :openai }
      expect(entry).not_to be_nil
      expect(entry[:model]).to eq('text-embedding-3-small')
    end
  end
end
