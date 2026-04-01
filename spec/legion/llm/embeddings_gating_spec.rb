# frozen_string_literal: true

require 'spec_helper'
require 'legion/llm/embeddings'

RSpec.describe 'Legion::LLM::Embeddings provider gating' do
  before do
    Legion::LLM.instance_variable_set(:@started, true)
    Legion::LLM.instance_variable_set(:@embedding_provider, nil)
    Legion::LLM.instance_variable_set(:@embedding_model, nil)
    Legion::LLM.instance_variable_set(:@embedding_fallback_chain, [])
  end

  after do
    Legion::LLM.instance_variable_set(:@started, nil)
    Legion::LLM.instance_variable_set(:@embedding_fallback_chain, nil)
  end

  describe 'Legion::LLM::Embeddings.generate with a disabled provider' do
    before do
      Legion::Settings[:llm][:providers][:azure] = { enabled: false }
    end

    it 'returns an error hash with :error matching /disabled/' do
      result = Legion::LLM::Embeddings.generate(text: 'hello', provider: :azure)
      expect(result[:vector]).to be_nil
      expect(result[:error]).to match(/disabled/)
    end

    it 'does not call RubyLLM.embed' do
      expect(RubyLLM).not_to receive(:embed)
      Legion::LLM::Embeddings.generate(text: 'hello', provider: :azure)
    end

    it 'includes the provider name in the error message' do
      result = Legion::LLM::Embeddings.generate(text: 'hello', provider: :azure)
      expect(result[:error]).to include('azure')
    end
  end

  describe 'Legion::LLM::Embeddings.generate_batch with a disabled provider' do
    before do
      Legion::Settings[:llm][:providers][:openai] = { enabled: false }
    end

    it 'returns an array of error hashes' do
      results = Legion::LLM::Embeddings.generate_batch(texts: %w[foo bar baz], provider: :openai)
      expect(results.size).to eq(3)
    end

    it 'each result has :vector nil and :error matching /disabled/' do
      results = Legion::LLM::Embeddings.generate_batch(texts: %w[foo bar], provider: :openai)
      expect(results).to all(include(vector: nil))
      expect(results.map { |r| r[:error] }).to all(match(/disabled/))
    end

    it 'each result includes :model, :dimensions, and :index for consistent shape' do
      results = Legion::LLM::Embeddings.generate_batch(texts: %w[foo bar], provider: :openai)
      results.each_with_index do |result, i|
        expect(result).to include(:model, :provider, :dimensions)
        expect(result[:dimensions]).to eq(0)
        expect(result[:index]).to eq(i)
      end
    end

    it 'does not call RubyLLM.embed' do
      expect(RubyLLM).not_to receive(:embed)
      Legion::LLM::Embeddings.generate_batch(texts: %w[foo], provider: :openai)
    end
  end

  describe 'Legion::LLM::Embeddings.generate with an enabled provider' do
    let(:mock_response) do
      double('EmbedResponse', vectors: [Array.new(1024, 0.5)], input_tokens: 7)
    end

    before do
      Legion::Settings[:llm][:providers][:openai] = { enabled: true }
      Legion::LLM.instance_variable_set(:@embedding_provider, :openai)
      Legion::LLM.instance_variable_set(:@embedding_model, 'text-embedding-3-small')
      allow(RubyLLM).to receive(:embed).and_return(mock_response)
    end

    it 'is not blocked and returns a vector' do
      result = Legion::LLM::Embeddings.generate(text: 'hello', provider: :openai)
      expect(result[:vector]).not_to be_nil
      expect(result[:error]).to be_nil
    end
  end

  describe 'Legion::LLM::Embeddings.generate_batch with an enabled provider' do
    let(:mock_response) do
      double('EmbedResponse', vectors: [Array.new(1024, 0.5), Array.new(1024, 0.6)])
    end

    before do
      Legion::Settings[:llm][:providers][:openai] = { enabled: true }
      Legion::LLM.instance_variable_set(:@embedding_provider, :openai)
      Legion::LLM.instance_variable_set(:@embedding_model, 'text-embedding-3-small')
      allow(RubyLLM).to receive(:embed).and_return(mock_response)
    end

    it 'is not blocked and returns vectors' do
      results = Legion::LLM::Embeddings.generate_batch(texts: %w[foo bar], provider: :openai)
      expect(results.size).to eq(2)
      expect(results.first[:vector]).not_to be_nil
    end
  end

  describe 'Legion::LLM::Embeddings provider_disabled? (private)' do
    it 'returns true when provider has enabled: false' do
      Legion::Settings[:llm][:providers][:bedrock] = { enabled: false }
      result = Legion::LLM::Embeddings.send(:provider_disabled?, :bedrock)
      expect(result).to be true
    end

    it 'returns false when provider has enabled: true' do
      Legion::Settings[:llm][:providers][:bedrock] = { enabled: true }
      result = Legion::LLM::Embeddings.send(:provider_disabled?, :bedrock)
      expect(result).to be false
    end

    it 'returns false when provider config is not a Hash' do
      allow(Legion::Settings).to receive(:dig).with(:llm, :providers, :unknown).and_return(nil)
      result = Legion::LLM::Embeddings.send(:provider_disabled?, :unknown)
      expect(result).to be false
    end

    it 'returns false when provider is nil' do
      result = Legion::LLM::Embeddings.send(:provider_disabled?, nil)
      expect(result).to be false
    end

    it 'returns false when Settings.dig raises' do
      allow(Legion::Settings).to receive(:dig).and_raise(StandardError.new('boom'))
      result = Legion::LLM::Embeddings.send(:provider_disabled?, :bedrock)
      expect(result).to be false
    end
  end
end
