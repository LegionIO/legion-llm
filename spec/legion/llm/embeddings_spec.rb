# frozen_string_literal: true

require 'spec_helper'
require 'legion/llm/embeddings'

RSpec.describe 'Legion::LLM embedding capability' do
  before do
    Legion::LLM.instance_variable_set(:@can_embed, nil)
    Legion::LLM.instance_variable_set(:@embedding_provider, nil)
    Legion::LLM.instance_variable_set(:@embedding_model, nil)
  end

  describe '.can_embed?' do
    it 'returns false before detection' do
      Legion::LLM.instance_variable_set(:@can_embed, nil)
      expect(Legion::LLM.can_embed?).to be false
    end

    it 'returns true after successful detection' do
      Legion::LLM.instance_variable_set(:@can_embed, true)
      expect(Legion::LLM.can_embed?).to be true
    end
  end

  describe '.embedding_provider' do
    it 'returns the detected provider symbol' do
      Legion::LLM.instance_variable_set(:@embedding_provider, :ollama)
      expect(Legion::LLM.embedding_provider).to eq(:ollama)
    end
  end

  describe '.embedding_model' do
    it 'returns the detected model string' do
      Legion::LLM.instance_variable_set(:@embedding_model, 'mxbai-embed-large')
      expect(Legion::LLM.embedding_model).to eq('mxbai-embed-large')
    end
  end
end

RSpec.describe Legion::LLM::Embeddings do
  before do
    allow(Legion::Settings).to receive(:dig).and_return(nil)
    Legion::LLM.instance_variable_set(:@can_embed, nil)
    Legion::LLM.instance_variable_set(:@embedding_provider, nil)
    Legion::LLM.instance_variable_set(:@embedding_model, nil)
  end

  describe '.generate' do
    it 'returns vector hash structure' do
      mock_response = double(vectors: [[0.1, 0.2, 0.3]], input_tokens: 5)
      allow(RubyLLM).to receive(:embed).and_return(mock_response)

      result = described_class.generate(text: 'hello world')
      expect(result[:vector]).to eq([0.1, 0.2, 0.3])
      expect(result[:dimensions]).to eq(3)
      expect(result[:tokens]).to eq(5)
    end

    it 'handles errors gracefully' do
      allow(RubyLLM).to receive(:embed).and_raise(StandardError.new('provider down'))
      result = described_class.generate(text: 'test')
      expect(result[:vector]).to be_nil
      expect(result[:error]).to include('provider down')
    end

    it 'passes custom model, provider, and dimensions' do
      mock_response = double(vectors: [[0.1]], input_tokens: 1)
      allow(RubyLLM).to receive(:embed).with('text', model: 'custom-model', provider: :bedrock, dimensions: 256).and_return(mock_response)

      result = described_class.generate(text: 'text', model: 'custom-model', provider: :bedrock, dimensions: 256)
      expect(result[:model]).to eq('custom-model')
      expect(result[:provider]).to eq(:bedrock)
    end

    it 'resolves provider from llm settings when not specified' do
      allow(Legion::Settings).to receive(:dig).with(:llm, :embeddings, :provider).and_return(nil)
      allow(Legion::Settings).to receive(:dig).with(:llm, :default_provider).and_return(:bedrock)
      allow(Legion::Settings).to receive(:dig).with(:llm, :embeddings, :default_model).and_return(nil)

      mock_response = double(vectors: [[0.1]], input_tokens: 1)
      allow(RubyLLM).to receive(:embed).and_return(mock_response)

      result = described_class.generate(text: 'test')
      expect(result[:provider]).to eq(:bedrock)
      expect(result[:model]).to eq('amazon.titan-embed-text-v2')
    end
  end

  describe '.generate_batch' do
    it 'returns array of vectors' do
      mock_response = double(vectors: [[0.1, 0.2], [0.3, 0.4]])
      allow(RubyLLM).to receive(:embed).and_return(mock_response)

      results = described_class.generate_batch(texts: %w[hello world])
      expect(results.size).to eq(2)
      expect(results.first[:vector]).to eq([0.1, 0.2])
      expect(results.last[:index]).to eq(1)
    end

    it 'handles batch errors gracefully' do
      allow(RubyLLM).to receive(:embed).and_raise(StandardError.new('batch fail'))
      results = described_class.generate_batch(texts: %w[a b])
      expect(results.size).to eq(2)
      expect(results.all? { |r| r[:vector].nil? }).to be true
    end
  end

  describe '.default_model' do
    it 'falls back to text-embedding-3-small when no provider' do
      expect(described_class.default_model).to eq('text-embedding-3-small')
    end

    it 'uses configured model' do
      allow(Legion::Settings).to receive(:dig).with(:llm, :embeddings, :default_model).and_return('custom')
      allow(Legion::Settings).to receive(:dig).with(:llm, :embeddings, :provider).and_return(nil)
      allow(Legion::Settings).to receive(:dig).with(:llm, :default_provider).and_return(nil)
      expect(described_class.default_model).to eq('custom')
    end

    it 'uses provider-specific default for bedrock' do
      allow(Legion::Settings).to receive(:dig).with(:llm, :embeddings, :default_model).and_return(nil)
      allow(Legion::Settings).to receive(:dig).with(:llm, :embeddings, :provider).and_return(:bedrock)
      allow(Legion::Settings).to receive(:dig).with(:llm, :default_provider).and_return(nil)
      expect(described_class.default_model).to eq('amazon.titan-embed-text-v2')
    end
  end
end
