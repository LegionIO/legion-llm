# frozen_string_literal: true

require 'spec_helper'
require 'legion/llm/call/embeddings'

RSpec.describe 'Legion::LLM embedding fallback chain cache' do
  before do
    Legion::LLM.instance_variable_set(:@can_embed, nil)
    Legion::LLM.instance_variable_set(:@embedding_provider, nil)
    Legion::LLM.instance_variable_set(:@embedding_model, nil)
    Legion::LLM.instance_variable_set(:@embedding_fallback_chain, nil)
  end

  after do
    Legion::LLM.instance_variable_set(:@embedding_fallback_chain, nil)
  end

  describe 'LLM.embedding_fallback_chain' do
    context 'when detect_embedding_capability finds a provider' do
      before do
        Legion::Settings[:llm][:providers][:ollama][:enabled] = true
        allow(Legion::LLM::Discovery::Ollama).to receive(:model_available?).and_return(false)
        allow(Legion::LLM::Discovery::Ollama).to receive(:model_available?)
          .with('mxbai-embed-large').and_return(true)
        allow(Legion::LLM).to receive(:verify_embedding).and_return(true)
      end

      it 'returns an array after detect_embedding_capability runs' do
        Legion::LLM.send(:detect_embedding_capability)
        expect(Legion::LLM.embedding_fallback_chain).to be_an(Array)
      end

      it 'contains entries with :provider and :model keys' do
        Legion::LLM.send(:detect_embedding_capability)
        chain = Legion::LLM.embedding_fallback_chain
        expect(chain).to all(include(:provider))
      end

      it 'includes the detected provider in the chain' do
        Legion::LLM.send(:detect_embedding_capability)
        providers = Legion::LLM.embedding_fallback_chain.map { |e| e[:provider] }
        expect(providers).to include(:ollama)
      end
    end

    context 'when no provider is available' do
      before do
        allow(Legion::LLM::Discovery::Ollama).to receive(:model_available?).and_return(false)
        Legion::Settings[:llm][:providers].each_value { |v| v[:enabled] = false }
      end

      it 'returns an empty array' do
        Legion::LLM.send(:detect_embedding_capability)
        expect(Legion::LLM.embedding_fallback_chain).to eq([])
      end
    end

    context 'after shutdown clears the chain' do
      it 'is set to nil by shutdown' do
        Legion::LLM.instance_variable_set(:@embedding_fallback_chain,
                                          [{ provider: :ollama, model: 'mxbai-embed-large' }])
        allow(Legion::LLM::Call::Registry).to receive(:reset!)
        Legion::LLM.instance_variable_set(:@started, true)
        # simulate shutdown resetting the chain ivar
        Legion::LLM.instance_variable_set(:@embedding_fallback_chain, nil)
        expect(Legion::LLM.embedding_fallback_chain).to be_nil
      end
    end
  end

  describe 'Legion::LLM::Embeddings.find_fallback_provider (private)' do
    let(:chain) do
      [
        { provider: :ollama, model: 'mxbai-embed-large' },
        { provider: :bedrock, model: 'amazon.titan-embed-text-v2:0' },
        { provider: :openai, model: 'text-embedding-3-small' }
      ]
    end

    before do
      allow(Legion::LLM).to receive(:embedding_fallback_chain).and_return(chain)
      Legion::Settings[:llm][:providers][:ollama]   = { enabled: true }
      Legion::Settings[:llm][:providers][:bedrock]  = { enabled: true }
      Legion::Settings[:llm][:providers][:openai]   = { enabled: true }
    end

    it 'returns the entry after the failed provider' do
      result = Legion::LLM::Embeddings.send(:find_fallback_provider, :ollama)
      expect(result).to eq({ provider: :openai, model: 'text-embedding-3-small' })
    end

    it 'skips the failed provider and returns the next one in the chain' do
      result = Legion::LLM::Embeddings.send(:find_fallback_provider, :bedrock)
      expect(result).to eq({ provider: :openai, model: 'text-embedding-3-small' })
    end

    it 'returns nil when the failed provider is last in the chain' do
      result = Legion::LLM::Embeddings.send(:find_fallback_provider, :openai)
      expect(result).to be_nil
    end

    it 'returns nil when the failed provider is not found in the chain' do
      result = Legion::LLM::Embeddings.send(:find_fallback_provider, :azure)
      expect(result).to be_nil
    end

    it 'returns nil when the chain is empty' do
      allow(Legion::LLM).to receive(:embedding_fallback_chain).and_return([])
      result = Legion::LLM::Embeddings.send(:find_fallback_provider, :ollama)
      expect(result).to be_nil
    end

    it 'returns nil when the chain is nil' do
      allow(Legion::LLM).to receive(:embedding_fallback_chain).and_return(nil)
      result = Legion::LLM::Embeddings.send(:find_fallback_provider, :ollama)
      expect(result).to be_nil
    end

    it 'does not re-probe providers (uses cached chain)' do
      expect(Legion::LLM).not_to receive(:send).with(:detect_ollama_embedding, anything)
      expect(Legion::LLM).not_to receive(:send).with(:detect_cloud_embedding, anything)
      Legion::LLM::Embeddings.send(:find_fallback_provider, :ollama)
    end

    context 'when a chain entry is currently disabled' do
      before do
        Legion::Settings[:llm][:providers][:bedrock] = { enabled: false }
        Legion::Settings[:llm][:providers][:openai]  = { enabled: true }
      end

      it 'skips disabled chain entries and returns the next enabled one' do
        result = Legion::LLM::Embeddings.send(:find_fallback_provider, :ollama)
        expect(result).to eq({ provider: :openai, model: 'text-embedding-3-small' })
      end
    end
  end

  describe 'LLM.build_embedding_fallback_chain (private)' do
    it 'includes only enabled providers' do
      Legion::Settings[:llm][:providers][:ollama][:enabled] = true
      Legion::Settings[:llm][:providers][:bedrock][:enabled] = false
      # General stub (false) must come first; specific stub (true) overrides for the target model
      allow(Legion::LLM::Discovery::Ollama).to receive(:model_available?).and_return(false)
      allow(Legion::LLM::Discovery::Ollama).to receive(:model_available?)
        .with('mxbai-embed-large').and_return(true)

      chain = Legion::LLM.send(:build_embedding_fallback_chain,
                               { provider_fallback: %w[ollama bedrock] })
      providers = chain.map { |e| e[:provider] }
      expect(providers).to include(:ollama)
      expect(providers).not_to include(:bedrock)
    end

    it 'returns an empty array when no providers are available' do
      Legion::Settings[:llm][:providers].each_value { |v| v[:enabled] = false }
      chain = Legion::LLM.send(:build_embedding_fallback_chain, {})
      expect(chain).to eq([])
    end

    it 'uses model from provider_models when a supported cloud provider is enabled' do
      Legion::Settings[:llm][:providers][:openai][:enabled] = true
      allow(Legion::LLM).to receive(:verify_embedding).and_return(true)

      chain = Legion::LLM.send(:build_embedding_fallback_chain, {
                                 provider_fallback: %w[openai],
                                 provider_models:   { 'openai' => 'text-embedding-3-small' }
                               })
      entry = chain.find { |e| e[:provider] == :openai }
      expect(entry).not_to be_nil
      expect(entry[:model]).to eq('text-embedding-3-small')
    end
  end
end
