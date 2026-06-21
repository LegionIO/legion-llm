# frozen_string_literal: true

require 'spec_helper'
require 'legion/llm/call/embeddings'

def native_embed_response(response = nil, vectors: nil, input_tokens: nil)
  vectors ||= response.vectors if response.respond_to?(:vectors)
  input_tokens ||= response.input_tokens if response.respond_to?(:input_tokens)
  {
    result: vectors || [Array.new(1024, 0.1)],
    usage:  Legion::LLM::Usage.new(input_tokens: input_tokens || 5)
  }
end

RSpec.describe 'Legion::LLM::Embeddings provider gating' do
  before do
    Legion::LLM.instance_variable_set(:@started, true)
    Legion::Settings[:llm][:embedding][:model] = nil
  end

  after do
    Legion::LLM.instance_variable_set(:@started, nil)
  end

  describe 'Legion::LLM::Embeddings.generate with no provider configured' do
    it 'raises LLMError when no model is configured' do
      expect { Legion::LLM::Embeddings.generate(text: 'hello') }.to raise_error(Legion::LLM::LLMError)
    end
  end

  describe 'Legion::LLM::Embeddings.generate when Dispatch raises' do
    before do
      Legion::Settings[:llm][:embedding][:model] = 'text-embedding-3-small'
      write_test_lane(provider: :azure, model: 'text-embedding-3-small', tier: :frontier, type: :embedding)
    end

    it 'propagates ProviderError (LLMError subclass) to callers' do
      allow(Legion::LLM::Call::Dispatch).to receive(:call)
        .and_raise(Legion::LLM::ProviderError.new('Native provider not registered: azure'))

      expect { Legion::LLM::Embeddings.generate(text: 'hello') }.to raise_error(Legion::LLM::ProviderError, /azure/)
    end

    it 'does not raise to callers' do
      allow(Legion::LLM::Call::Dispatch).to receive(:call)
        .and_raise(StandardError.new('connection refused'))

      expect { Legion::LLM::Embeddings.generate(text: 'hello') }.not_to raise_error
    end
  end

  describe 'Legion::LLM::Embeddings.generate with an enabled provider' do
    let(:mock_response) do
      double('EmbedResponse', vectors: [Array.new(1024, 0.5)], input_tokens: 7)
    end

    before do
      Legion::Settings[:llm][:embedding][:model] = 'text-embedding-3-small'
      write_test_lane(provider: :openai, model: 'text-embedding-3-small', tier: :frontier, type: :embedding)
      allow(Legion::LLM::Call::Dispatch).to receive(:call).and_return(native_embed_response(mock_response))
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
      Legion::Settings[:llm][:embedding][:model] = 'text-embedding-3-small'
      write_test_lane(provider: :openai, model: 'text-embedding-3-small', tier: :frontier, type: :embedding)
      allow(Legion::LLM::Call::Dispatch).to receive(:call).and_return(native_embed_response(mock_response))
    end

    it 'is not blocked and returns vectors' do
      results = Legion::LLM::Embeddings.generate_batch(texts: %w[foo bar], provider: :openai)
      expect(results.size).to eq(2)
      expect(results.first[:vector]).not_to be_nil
    end
  end

  describe 'Legion::LLM::Embeddings.generate_batch when Dispatch raises' do
    before do
      Legion::Settings[:llm][:embedding][:model] = 'text-embedding-3-small'
      write_test_lane(provider: :openai, model: 'text-embedding-3-small', tier: :frontier, type: :embedding)
    end

    it 'returns error hashes for all texts' do
      allow(Legion::LLM::Call::Dispatch).to receive(:call)
        .and_raise(StandardError.new('batch dispatch failed'))

      results = Legion::LLM::Embeddings.generate_batch(texts: %w[foo bar baz], provider: :openai)
      expect(results.size).to eq(3)
      expect(results).to all(include(vector: nil))
      expect(results.map { |r| r[:error] }).to all(include('batch dispatch failed'))
    end
  end
end
