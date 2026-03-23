# frozen_string_literal: true

require 'spec_helper'
require 'legion/llm/shadow_eval'

RSpec.describe Legion::LLM::ShadowEval do
  before { described_class.clear_history }

  describe '.enabled?' do
    it 'returns false when not configured' do
      allow(Legion::Settings).to receive(:dig).with(:llm, :shadow, :enabled).and_return(nil)
      expect(described_class.enabled?).to be false
    end

    it 'returns true when enabled' do
      allow(Legion::Settings).to receive(:dig).with(:llm, :shadow, :enabled).and_return(true)
      expect(described_class.enabled?).to be true
    end
  end

  describe '.should_sample?' do
    it 'returns false when disabled' do
      allow(Legion::Settings).to receive(:dig).with(:llm, :shadow, :enabled).and_return(false)
      expect(described_class.should_sample?).to be false
    end

    it 'samples based on rate when enabled' do
      allow(Legion::Settings).to receive(:dig).with(:llm, :shadow, :enabled).and_return(true)
      allow(Legion::Settings).to receive(:dig).with(:llm, :shadow, :sample_rate).and_return(1.0)
      expect(described_class.should_sample?).to be true
    end

    it 'never samples at rate 0' do
      allow(Legion::Settings).to receive(:dig).with(:llm, :shadow, :enabled).and_return(true)
      allow(Legion::Settings).to receive(:dig).with(:llm, :shadow, :sample_rate).and_return(0.0)
      expect(described_class.should_sample?).to be false
    end
  end

  describe '.compare' do
    it 'computes length ratio' do
      primary = { content: 'short', model: 'gpt-4o', usage: 10 }
      shadow = { content: 'also short text', model: 'gpt-4o-mini', usage: 5 }
      result = described_class.compare(primary, shadow, 'gpt-4o-mini')
      expect(result[:length_ratio]).to eq(15.0 / 5)
      expect(result[:primary_model]).to eq('gpt-4o')
      expect(result[:shadow_model]).to eq('gpt-4o-mini')
    end

    it 'handles nil content' do
      primary = { content: nil, model: 'gpt-4o', usage: 0 }
      shadow = { content: 'text', model: 'mini', usage: 0 }
      result = described_class.compare(primary, shadow, 'mini')
      expect(result[:length_ratio]).to eq(0.0)
    end

    it 'estimates costs when usage is a hash' do
      primary = { content: 'hello', model: 'gpt-4o', usage: { input_tokens: 100, output_tokens: 50 } }
      shadow = { content: 'world', model: 'gpt-4o-mini', usage: { input_tokens: 100, output_tokens: 50 } }
      result = described_class.compare(primary, shadow, 'gpt-4o-mini')
      expect(result[:primary_cost]).to be > 0
      expect(result[:shadow_cost]).to be > 0
      expect(result).to have_key(:cost_savings)
    end

    it 'returns zero costs when usage is not a hash' do
      primary = { content: 'hi', model: 'gpt-4o', usage: 10 }
      shadow = { content: 'hi', model: 'mini', usage: 5 }
      result = described_class.compare(primary, shadow, 'mini')
      expect(result[:primary_cost]).to eq(0.0)
      expect(result[:shadow_cost]).to eq(0.0)
    end
  end

  describe '.history' do
    it 'starts empty' do
      expect(described_class.history).to be_empty
    end

    it 'accumulates recorded comparisons' do
      primary = { content: 'a', model: 'gpt-4o', usage: 1 }
      shadow = { content: 'b', model: 'mini', usage: 1 }
      comparison = described_class.compare(primary, shadow, 'mini')
      described_class.send(:record, comparison)
      expect(described_class.history.size).to eq(1)
    end

    it 'caps at MAX_HISTORY' do
      primary = { content: 'x', model: 'm', usage: 0 }
      shadow = { content: 'y', model: 's', usage: 0 }
      (described_class::MAX_HISTORY + 5).times do
        described_class.send(:record, described_class.compare(primary, shadow, 's'))
      end
      expect(described_class.history.size).to eq(described_class::MAX_HISTORY)
    end
  end

  describe '.summary' do
    it 'returns empty summary when no history' do
      result = described_class.summary
      expect(result[:total_evaluations]).to eq(0)
      expect(result[:avg_length_ratio]).to eq(0.0)
      expect(result[:models_evaluated]).to be_empty
    end

    it 'summarizes recorded evaluations' do
      primary = { content: 'hello world', model: 'gpt-4o', usage: { input_tokens: 100, output_tokens: 50 } }
      shadow = { content: 'hi', model: 'gpt-4o-mini', usage: { input_tokens: 100, output_tokens: 50 } }
      comp = described_class.compare(primary, shadow, 'gpt-4o-mini')
      described_class.send(:record, comp)

      result = described_class.summary
      expect(result[:total_evaluations]).to eq(1)
      expect(result[:avg_length_ratio]).to be > 0
      expect(result[:models_evaluated]).to include('gpt-4o-mini')
      expect(result[:total_primary_cost]).to be >= 0
    end
  end

  describe '.clear_history' do
    it 'empties the history' do
      primary = { content: 'a', model: 'm', usage: 0 }
      shadow = { content: 'b', model: 's', usage: 0 }
      described_class.send(:record, described_class.compare(primary, shadow, 's'))
      expect(described_class.history).not_to be_empty

      described_class.clear_history
      expect(described_class.history).to be_empty
    end
  end
end
