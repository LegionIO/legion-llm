# frozen_string_literal: true

require 'spec_helper'
require 'legion/llm/cost_tracker'

RSpec.describe Legion::LLM::CostTracker do
  before { described_class.clear }
  after  { described_class.clear }

  describe '.record' do
    it 'returns a Hash with expected keys' do
      entry = described_class.record(model: 'gpt-4o', input_tokens: 1000, output_tokens: 500)
      expect(entry).to include(:model, :provider, :input_tokens, :output_tokens, :cost_usd, :recorded_at)
    end

    it 'stores the model and token counts' do
      entry = described_class.record(model: 'gpt-4o', input_tokens: 1000, output_tokens: 500)
      expect(entry[:model]).to eq('gpt-4o')
      expect(entry[:input_tokens]).to eq(1000)
      expect(entry[:output_tokens]).to eq(500)
    end

    it 'calculates cost correctly for gpt-4o (2.50/1M in, 10.0/1M out)' do
      # 1000 * 2.50 / 1_000_000 + 500 * 10.0 / 1_000_000 = 0.0025 + 0.005 = 0.0075
      entry = described_class.record(model: 'gpt-4o', input_tokens: 1000, output_tokens: 500)
      expect(entry[:cost_usd]).to be_within(0.000001).of(0.0075)
    end

    it 'calculates cost correctly for claude-sonnet-4-6 (3.0/1M in, 15.0/1M out)' do
      # 1000 * 3.0 / 1_000_000 + 500 * 15.0 / 1_000_000 = 0.003 + 0.0075 = 0.0105
      entry = described_class.record(model: 'claude-sonnet-4-6', input_tokens: 1000, output_tokens: 500)
      expect(entry[:cost_usd]).to be_within(0.000001).of(0.0105)
    end

    it 'stores the provider when given' do
      entry = described_class.record(model: 'gpt-4o', input_tokens: 100, output_tokens: 50, provider: :openai)
      expect(entry[:provider]).to eq(:openai)
    end

    it 'stores nil provider when not given' do
      entry = described_class.record(model: 'gpt-4o', input_tokens: 100, output_tokens: 50)
      expect(entry[:provider]).to be_nil
    end

    it 'records a timestamp' do
      entry = described_class.record(model: 'gpt-4o', input_tokens: 100, output_tokens: 50)
      expect(entry[:recorded_at]).to be_a(Time)
    end

    it 'accumulates multiple records' do
      described_class.record(model: 'gpt-4o', input_tokens: 100, output_tokens: 50)
      described_class.record(model: 'gpt-4o', input_tokens: 200, output_tokens: 100)
      expect(described_class.summary[:total_requests]).to eq(2)
    end

    it 'uses fallback pricing for unknown models' do
      # Fallback: input: 5.0, output: 15.0
      # 1000 * 5.0 / 1_000_000 + 500 * 15.0 / 1_000_000 = 0.005 + 0.0075 = 0.0125
      entry = described_class.record(model: 'unknown-model-xyz', input_tokens: 1000, output_tokens: 500)
      expect(entry[:cost_usd]).to be_within(0.000001).of(0.0125)
    end
  end

  describe '.summary' do
    context 'with no records' do
      it 'returns zero totals' do
        result = described_class.summary
        expect(result[:total_cost_usd]).to eq(0.0)
        expect(result[:total_requests]).to eq(0)
        expect(result[:total_input_tokens]).to eq(0)
        expect(result[:total_output_tokens]).to eq(0)
        expect(result[:by_model]).to eq({})
      end
    end

    context 'with multiple records' do
      before do
        described_class.record(model: 'gpt-4o', input_tokens: 1000, output_tokens: 500)
        described_class.record(model: 'gpt-4o', input_tokens: 2000, output_tokens: 1000)
        described_class.record(model: 'claude-sonnet-4-6', input_tokens: 500, output_tokens: 250)
      end

      it 'sums total requests' do
        expect(described_class.summary[:total_requests]).to eq(3)
      end

      it 'sums total input tokens' do
        expect(described_class.summary[:total_input_tokens]).to eq(3500)
      end

      it 'sums total output tokens' do
        expect(described_class.summary[:total_output_tokens]).to eq(1750)
      end

      it 'sums total cost across all records' do
        expect(described_class.summary[:total_cost_usd]).to be > 0
      end

      it 'groups by model in :by_model' do
        by_model = described_class.summary[:by_model]
        expect(by_model.keys).to contain_exactly('gpt-4o', 'claude-sonnet-4-6')
        expect(by_model['gpt-4o'][:requests]).to eq(2)
        expect(by_model['claude-sonnet-4-6'][:requests]).to eq(1)
      end
    end

    context 'with since: filter' do
      it 'excludes records before the cutoff' do
        old_time = Time.now - 3600
        new_time = Time.now

        allow(Time).to receive(:now).and_return(old_time)
        described_class.record(model: 'gpt-4o', input_tokens: 100, output_tokens: 50)

        allow(Time).to receive(:now).and_return(new_time)
        described_class.record(model: 'gpt-4o', input_tokens: 200, output_tokens: 100)

        result = described_class.summary(since: old_time + 1)
        expect(result[:total_requests]).to eq(1)
      end

      it 'includes all records when since is before all entries' do
        described_class.record(model: 'gpt-4o', input_tokens: 100, output_tokens: 50)
        described_class.record(model: 'gpt-4o', input_tokens: 200, output_tokens: 100)
        result = described_class.summary(since: Time.now - 86_400)
        expect(result[:total_requests]).to eq(2)
      end
    end
  end

  describe '.clear' do
    it 'removes all records' do
      described_class.record(model: 'gpt-4o', input_tokens: 100, output_tokens: 50)
      described_class.clear
      expect(described_class.summary[:total_requests]).to eq(0)
    end
  end

  describe '.pricing_for' do
    it 'returns known pricing for gpt-4o' do
      pricing = described_class.pricing_for('gpt-4o')
      expect(pricing).to eq({ input: 2.50, output: 10.0 })
    end

    it 'returns known pricing for claude-sonnet-4-6' do
      pricing = described_class.pricing_for('claude-sonnet-4-6')
      expect(pricing).to eq({ input: 3.0, output: 15.0 })
    end

    it 'returns fallback pricing for unknown models' do
      pricing = described_class.pricing_for('some-unknown-model')
      expect(pricing).to eq({ input: 5.0, output: 15.0 })
    end

    it 'accepts model as a symbol and coerces it' do
      pricing = described_class.pricing_for('gpt-4o-mini')
      expect(pricing[:input]).to eq(0.15)
    end
  end
end
