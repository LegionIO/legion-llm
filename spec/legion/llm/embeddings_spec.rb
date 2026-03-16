# frozen_string_literal: true

require 'spec_helper'
require 'legion/llm/embeddings'

RSpec.describe Legion::LLM::Embeddings do
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

    it 'passes custom model and dimensions' do
      mock_response = double(vectors: [[0.1]], input_tokens: 1)
      allow(RubyLLM).to receive(:embed).with('text', model: 'custom-model', dimensions: 256).and_return(mock_response)

      result = described_class.generate(text: 'text', model: 'custom-model', dimensions: 256)
      expect(result[:model]).to eq('custom-model')
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
    it 'falls back to text-embedding-3-small' do
      allow(Legion::Settings).to receive(:dig).with(:llm, :embeddings, :default_model).and_return(nil)
      expect(described_class.default_model).to eq('text-embedding-3-small')
    end

    it 'uses configured model' do
      allow(Legion::Settings).to receive(:dig).with(:llm, :embeddings, :default_model).and_return('custom')
      expect(described_class.default_model).to eq('custom')
    end
  end
end
