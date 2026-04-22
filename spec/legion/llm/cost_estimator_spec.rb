# frozen_string_literal: true

require 'spec_helper'

RSpec.describe Legion::LLM::Metering::Pricing do
  describe '.estimate' do
    it 'calculates cost for Claude Opus 4.6' do
      cost = described_class.estimate(model_id: 'claude-opus-4-6', input_tokens: 1000, output_tokens: 500)
      expect(cost).to eq(0.0525)
    end

    it 'calculates cost for GPT-4o' do
      cost = described_class.estimate(model_id: 'gpt-4o', input_tokens: 10_000, output_tokens: 2000)
      expect(cost).to eq(0.045)
    end

    it 'handles zero tokens' do
      cost = described_class.estimate(model_id: 'claude-opus-4-6', input_tokens: 0, output_tokens: 0)
      expect(cost).to eq(0.0)
    end

    it 'uses default pricing for unknown models' do
      cost = described_class.estimate(model_id: 'unknown-model', input_tokens: 1_000_000, output_tokens: 1_000_000)
      expect(cost).to eq(4.0)
    end

    it 'handles nil model_id' do
      cost = described_class.estimate(model_id: nil, input_tokens: 1000, output_tokens: 500)
      expect(cost).to be_a(Float)
    end

    it 'handles nil tokens' do
      cost = described_class.estimate(model_id: 'gpt-4o')
      expect(cost).to eq(0.0)
    end
  end

  describe '.resolve_price' do
    it 'returns exact match' do
      expect(described_class.resolve_price('claude-opus-4-6')).to eq([15.0, 75.0])
    end

    it 'normalizes to lowercase' do
      expect(described_class.resolve_price('Claude-Opus-4-6')).to eq([15.0, 75.0])
    end

    it 'matches with fuzzy search' do
      expect(described_class.resolve_price('us.anthropic.claude-opus-4-6-v1')).to eq([15.0, 75.0])
    end

    it 'returns default for completely unknown model' do
      expect(described_class.resolve_price('my-custom-model')).to eq([1.0, 3.0])
    end
  end

  describe 'PRICING' do
    it 'has entries for major providers' do
      models = described_class::PRICING.keys
      expect(models).to include('claude-opus-4-6')
      expect(models).to include('gpt-4o')
      expect(models).to include('gemini-2.5-pro')
    end

    it 'has valid price arrays with two elements' do
      described_class::PRICING.each_value do |price|
        expect(price).to be_an(Array)
        expect(price.length).to eq(2)
        expect(price[0]).to be > 0
        expect(price[1]).to be > 0
      end
    end
  end
end
