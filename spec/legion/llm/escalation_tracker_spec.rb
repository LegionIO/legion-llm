# frozen_string_literal: true

require 'spec_helper'
require 'legion/llm/escalation_tracker'

RSpec.describe Legion::LLM::EscalationTracker do
  before { described_class.clear }

  describe '.record' do
    it 'stores an escalation entry' do
      described_class.record(from_model: 'gpt-4o-mini', to_model: 'gpt-4o', reason: 'quality_failure')
      expect(described_class.history.size).to eq(1)
      expect(described_class.history.first[:from_model]).to eq('gpt-4o-mini')
    end

    it 'caps history at MAX_HISTORY' do
      (described_class::MAX_HISTORY + 10).times do |i|
        described_class.record(from_model: "m#{i}", to_model: "m#{i + 1}", reason: 'test')
      end
      expect(described_class.history.size).to eq(described_class::MAX_HISTORY)
    end
  end

  describe '.summary' do
    it 'returns empty summary when no history' do
      result = described_class.summary
      expect(result[:total_escalations]).to eq(0)
      expect(result[:by_reason]).to be_empty
    end

    it 'aggregates by reason and model' do
      described_class.record(from_model: 'haiku', to_model: 'sonnet', reason: 'quality')
      described_class.record(from_model: 'haiku', to_model: 'opus', reason: 'quality')
      described_class.record(from_model: 'mini', to_model: 'gpt-4o', reason: 'timeout')

      result = described_class.summary
      expect(result[:total_escalations]).to eq(3)
      expect(result[:by_reason]).to eq({ 'quality' => 2, 'timeout' => 1 })
      expect(result[:by_source_model]).to include('haiku' => 2)
      expect(result[:recent].size).to eq(3)
    end
  end

  describe '.escalation_rate' do
    it 'counts recent escalations within window' do
      described_class.record(from_model: 'a', to_model: 'b', reason: 'test')
      result = described_class.escalation_rate(window_seconds: 60)
      expect(result[:count]).to eq(1)
    end
  end

  describe '.clear' do
    it 'empties history' do
      described_class.record(from_model: 'a', to_model: 'b', reason: 'test')
      described_class.clear
      expect(described_class.history).to be_empty
    end
  end
end
