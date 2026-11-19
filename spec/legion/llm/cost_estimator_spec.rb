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

  describe 'registered pricing defaults' do
    it 'has entries for major providers' do
      models = Legion::LLM::Settings.pricing_defaults.keys
      expect(models).to include('claude-opus-4-6')
      expect(models).to include('gpt-4o')
      expect(models).to include('gemini-2.5-pro')
    end

    it 'has input and output rates for every configured model' do
      Legion::LLM::Settings.pricing_defaults.each_value do |price|
        expect(price.fetch(:input)).to be > 0
        expect(price.fetch(:output)).to be > 0
      end
    end
  end

  describe 'shared pricing resolution' do
    after { Legion::LLM::Metering::Recorder.clear }

    ['gpt-4o', 'custom-model', :custom_model].each do |model|
      it "honors configured rates consistently for #{model}" do
        Legion::Settings[:llm][:pricing] = { model => { input: 1.25, output: 2.5 } }
        usage = { input_tokens: 1_000_000, output_tokens: 1_000_000 }
        response = { model: model.to_s, content: 'example', usage: usage }

        expect(described_class.estimate(model_id: model, **usage)).to eq(3.75)
        expect(Legion::LLM::Metering::Recorder.record(model: model, **usage)[:cost_usd]).to eq(3.75)
        comparison = Legion::LLM::Quality::ShadowEval.compare(response, response, model)
        expect(comparison).to include(primary_cost: 3.75, shadow_cost: 3.75, cost_savings: 0.0)
      end
    end

    it 'uses the same configurable unknown-model policy for all cost consumers' do
      Legion::Settings[:llm][:metering][:unknown_model_price] = { input: 7.0, output: 11.0 }
      usage = { input_tokens: 1_000_000, output_tokens: 1_000_000 }
      response = { model: 'unknown-model', content: 'example', usage: usage }

      expect(described_class.estimate(model_id: response[:model], **usage)).to eq(18.0)
      expect(Legion::LLM::Metering::Recorder.record(model: response[:model], **usage)[:cost_usd]).to eq(18.0)
      expect(Legion::LLM::Quality::ShadowEval.compare(response, response, response[:model]))
        .to include(primary_cost: 18.0, shadow_cost: 18.0)
    end

    it 'matches the most specific decorated model name and does not guess from empty identifiers' do
      expect(described_class.resolve_price('gpt-4o-mini-2026-01-01')).to eq([0.15, 0.60])
      expect(described_class.resolve_price('')).to eq([1.0, 3.0])
    end

    it 'accepts zero rates and string-key configuration' do
      Legion::Settings[:llm][:pricing] = { 'free-model' => { 'input' => 0, 'output' => 0 } }
      expect(described_class.estimate(model_id: 'free-model', input_tokens: 1000, output_tokens: 1000)).to eq(0.0)
    end

    [nil, {}, { input: -1, output: 3 }, { input: Float::INFINITY, output: 3 }, { input: '1', output: 3 }].each do |price|
      it "rejects invalid configured rates #{price.inspect} instead of inventing a price" do
        Legion::Settings[:llm][:pricing] = { 'broken-model' => price }
        expect { described_class.resolve_price('broken-model') }.to raise_error(ArgumentError, /pricing/)
      end
    end
  end
end
