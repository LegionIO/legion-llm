# frozen_string_literal: true

require 'spec_helper'
require 'legion/llm/router/arbitrage'

RSpec.describe Legion::LLM::Arbitrage do
  before do
    Legion::Settings[:llm][:arbitrage] = {}
  end

  describe '.enabled?' do
    it 'returns false by default' do
      expect(described_class.enabled?).to be false
    end

    it 'returns true when enabled in settings' do
      Legion::Settings[:llm][:arbitrage] = { enabled: true }
      expect(described_class.enabled?).to be true
    end

    it 'returns false when explicitly disabled' do
      Legion::Settings[:llm][:arbitrage] = { enabled: false }
      expect(described_class.enabled?).to be false
    end
  end

  describe '.cost_table' do
    it 'returns the default cost table when no overrides configured' do
      expect(described_class.cost_table).to include(
        'claude-sonnet-4-6' => { input: 3.0, output: 15.0 },
        'gpt-4o'            => { input: 2.5, output: 10.0 },
        'gemini-2.0-flash'  => { input: 0.10, output: 0.40 }
      )
    end

    it 'merges settings-defined overrides with defaults' do
      Legion::Settings[:llm][:arbitrage] = {
        cost_table: { 'my-custom-model' => { input: 1.0, output: 2.0 } }
      }
      table = described_class.cost_table
      expect(table['my-custom-model']).to eq({ input: 1.0, output: 2.0 })
      expect(table['gpt-4o']).to eq({ input: 2.5, output: 10.0 })
    end

    it 'allows overriding a default model price' do
      Legion::Settings[:llm][:arbitrage] = {
        cost_table: { 'gpt-4o' => { input: 1.0, output: 5.0 } }
      }
      expect(described_class.cost_table['gpt-4o']).to eq({ input: 1.0, output: 5.0 })
    end
  end

  describe '.estimated_cost' do
    it 'calculates cost for a known model' do
      # claude-sonnet-4-6: $3.00/1M input, $15.00/1M output
      # 1000 input + 500 output = (3.0*1000 + 15.0*500) / 1_000_000 = 0.0105
      cost = described_class.estimated_cost(model: 'claude-sonnet-4-6', input_tokens: 1000, output_tokens: 500)
      expect(cost).to be_within(0.0001).of(0.0105)
    end

    it 'returns 0.0 for local models (llama3)' do
      cost = described_class.estimated_cost(model: 'llama3', input_tokens: 5000, output_tokens: 2000)
      expect(cost).to eq(0.0)
    end

    it 'returns nil for an unknown model' do
      cost = described_class.estimated_cost(model: 'unknown-model-xyz', input_tokens: 1000, output_tokens: 500)
      expect(cost).to be_nil
    end

    it 'uses default token counts when not specified' do
      cost = described_class.estimated_cost(model: 'gpt-4o')
      # 2.5*1000 + 10.0*500 = 7500 / 1_000_000 = 0.0075
      expect(cost).to be_within(0.0001).of(0.0075)
    end
  end

  describe '.cheapest_for' do
    before do
      Legion::Settings[:llm][:arbitrage] = { enabled: true, quality_floor: 0.7 }
    end

    it 'returns nil when disabled' do
      Legion::Settings[:llm][:arbitrage] = { enabled: false }
      expect(described_class.cheapest_for(capability: :basic)).to be_nil
    end

    it 'returns the cheapest model for basic capability' do
      result = described_class.cheapest_for(capability: :basic)
      # llama3 costs 0.0, so should be cheapest
      expect(result).to eq('llama3')
    end

    it 'returns nil when max_cost is too low for all models' do
      # Even llama3 at 0.0 should pass, but set max_cost < 0 to force none
      result = described_class.cheapest_for(capability: :basic, max_cost: -0.01)
      expect(result).to be_nil
    end

    it 'filters by max_cost when specified' do
      # claude-sonnet-4-6 at 1000/500 tokens = 0.0105, gpt-4o = 0.0075
      # gemini-2.0-flash at 1000/500 tokens = (0.10*1000+0.40*500)/1M = 0.0003
      result = described_class.cheapest_for(capability: :basic, max_cost: 0.001)
      # Only gemini-2.0-flash and llama3 fall under 0.001
      expect(%w[gemini-2.0-flash llama3]).to include(result)
    end

    it 'excludes low-quality models for :reasoning capability' do
      result = described_class.cheapest_for(capability: :reasoning)
      expect(result).not_to eq('gpt-4o-mini')
      expect(result).not_to eq('llama3')
    end

    it 'returns a known model for :moderate capability' do
      result = described_class.cheapest_for(capability: :moderate)
      expect(described_class.cost_table.keys).to include(result)
    end
  end
end
