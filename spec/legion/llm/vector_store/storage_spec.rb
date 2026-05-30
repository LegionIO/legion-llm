# frozen_string_literal: true

require 'spec_helper'
require 'legion/llm/vector_store/storage'

RSpec.describe Legion::LLM::VectorStore::Storage do
  describe '.generate_id' do
    it 'generates an id with the given prefix' do
      id = described_class.generate_id('vs')
      expect(id).to match(/\Avs_[0-9a-f]{20}\z/)
    end

    it 'generates unique ids' do
      ids = Array.new(10) { described_class.generate_id('vs') }
      expect(ids.uniq.size).to eq(10)
    end
  end

  describe '.now_ts' do
    it 'returns an integer Unix timestamp' do
      ts = described_class.now_ts
      expect(ts).to be_a(Integer)
      expect(ts).to be > 0
    end

    it 'is within 5 seconds of Time.now' do
      expect(described_class.now_ts).to be_within(5).of(Time.now.to_i)
    end
  end

  describe '.cosine_similarity' do
    it 'returns 1.0 for identical vectors' do
      v = [1.0, 0.0, 0.0]
      result = described_class.cosine_similarity(v, v)
      expect(result).to be_within(0.0001).of(1.0)
    end

    it 'returns 0.0 for orthogonal vectors' do
      a = [1.0, 0.0]
      b = [0.0, 1.0]
      result = described_class.cosine_similarity(a, b)
      expect(result).to be_within(0.0001).of(0.0)
    end

    it 'returns near -1.0 for opposing vectors' do
      a = [1.0, 0.0]
      b = [-1.0, 0.0]
      result = described_class.cosine_similarity(a, b)
      expect(result).to be_within(0.0001).of(-1.0)
    end

    it 'handles fractional vectors correctly' do
      a = [0.6, 0.8]
      b = [0.6, 0.8]
      result = described_class.cosine_similarity(a, b)
      expect(result).to be_within(0.0001).of(1.0)
    end

    it 'returns 0.0 for a zero vector' do
      a = [0.0, 0.0]
      b = [1.0, 0.5]
      result = described_class.cosine_similarity(a, b)
      expect(result).to eq(0.0)
    end

    it 'returns 0.0 for mismatched dimension vectors' do
      a = [1.0, 0.0, 0.5]
      b = [1.0, 0.0]
      result = described_class.cosine_similarity(a, b)
      expect(result).to eq(0.0)
    end
  end

  describe '.data_available?' do
    it 'returns false when Legion::Data is not defined' do
      hide_const('Legion::Data') if defined?(Legion::Data)
      expect(described_class.data_available?).to be false
    end
  end
end
