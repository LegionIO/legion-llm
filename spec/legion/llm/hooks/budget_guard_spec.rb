# frozen_string_literal: true

require 'spec_helper'
require 'legion/llm/hooks'
require 'legion/llm/hooks/budget_guard'
require 'legion/llm/metering/tracker'

RSpec.describe Legion::LLM::Hooks::BudgetGuard do
  before do
    Legion::LLM::Metering::Recorder.clear
  end

  after do
    Legion::LLM::Hooks.reset!
    Legion::LLM::Metering::Recorder.clear
  end

  describe '.install' do
    it 'registers a before_chat hook' do
      expect { described_class.install }.to change {
        Legion::LLM::Hooks.instance_variable_get(:@before_chat).size
      }.by(1)
    end
  end

  describe '.check_budget' do
    context 'when no budget is configured' do
      before { allow(described_class).to receive(:session_budget).and_return(0.0) }

      it 'returns nil (allows request)' do
        expect(described_class.check_budget('gpt-4o')).to be_nil
      end
    end

    context 'when budget is configured and not exceeded' do
      before { allow(described_class).to receive(:session_budget).and_return(1.0) }

      it 'returns nil (allows request)' do
        expect(described_class.check_budget('gpt-4o')).to be_nil
      end
    end

    context 'when budget is exceeded' do
      before do
        allow(described_class).to receive(:session_budget).and_return(0.01)
        Legion::LLM::Metering::Recorder.record(model: 'gpt-4o', input_tokens: 100_000, output_tokens: 50_000)
      end

      it 'returns a block action' do
        result = described_class.check_budget('gpt-4o')
        expect(result[:action]).to eq(:block)
        expect(result[:response][:error]).to eq('budget_exceeded')
      end
    end
  end

  describe '.remaining' do
    context 'when no budget configured' do
      before { allow(described_class).to receive(:session_budget).and_return(0.0) }

      it 'returns infinity' do
        expect(described_class.remaining).to eq(Float::INFINITY)
      end
    end

    context 'when budget configured' do
      before { allow(described_class).to receive(:session_budget).and_return(5.0) }

      it 'returns remaining budget' do
        Legion::LLM::Metering::Recorder.record(model: 'gpt-4o', input_tokens: 1_000_000, output_tokens: 0)
        remaining = described_class.remaining
        expect(remaining).to be < 5.0
        expect(remaining).to be > 0.0
      end
    end
  end

  describe '.status' do
    before { allow(described_class).to receive(:session_budget).and_return(10.0) }

    it 'returns current budget status' do
      result = described_class.status
      expect(result[:enforcing]).to be true
      expect(result[:budget_usd]).to eq(10.0)
      expect(result[:spent_usd]).to eq(0.0)
      expect(result[:remaining_usd]).to eq(10.0)
      expect(result[:ratio]).to eq(0.0)
    end

    it 'reflects spending' do
      Legion::LLM::Metering::Recorder.record(model: 'gpt-4o', input_tokens: 1_000_000, output_tokens: 500_000)
      result = described_class.status
      expect(result[:spent_usd]).to be > 0
      expect(result[:remaining_usd]).to be < 10.0
    end
  end

  describe '.enforcing?' do
    it 'returns false when no budget' do
      allow(described_class).to receive(:session_budget).and_return(0.0)
      expect(described_class.enforcing?).to be false
    end

    it 'returns true when budget is set' do
      allow(described_class).to receive(:session_budget).and_return(5.0)
      expect(described_class.enforcing?).to be true
    end
  end
end
