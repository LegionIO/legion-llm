# frozen_string_literal: true

require 'spec_helper'
require 'legion/llm/scheduling'

RSpec.describe Legion::LLM::Scheduling do
  before do
    Legion::Settings[:llm][:scheduling] = {}
  end

  describe '.enabled?' do
    it 'returns false by default' do
      expect(described_class.enabled?).to be false
    end

    it 'returns true when enabled in settings' do
      Legion::Settings[:llm][:scheduling] = { enabled: true }
      expect(described_class.enabled?).to be true
    end

    it 'returns false when explicitly disabled' do
      Legion::Settings[:llm][:scheduling] = { enabled: false }
      expect(described_class.enabled?).to be false
    end
  end

  describe '.peak_hours?' do
    context 'with default peak range (14-22 UTC)' do
      it 'returns true during peak hours (e.g., 16:00 UTC)' do
        frozen = Time.utc(2026, 3, 21, 16, 0, 0)
        allow(Time).to receive(:now).and_return(frozen)
        expect(described_class.peak_hours?).to be true
      end

      it 'returns true at the start of peak (14:00 UTC)' do
        frozen = Time.utc(2026, 3, 21, 14, 0, 0)
        allow(Time).to receive(:now).and_return(frozen)
        expect(described_class.peak_hours?).to be true
      end

      it 'returns true at the end of peak (22:00 UTC)' do
        frozen = Time.utc(2026, 3, 21, 22, 0, 0)
        allow(Time).to receive(:now).and_return(frozen)
        expect(described_class.peak_hours?).to be true
      end

      it 'returns false outside peak hours (e.g., 08:00 UTC)' do
        frozen = Time.utc(2026, 3, 21, 8, 0, 0)
        allow(Time).to receive(:now).and_return(frozen)
        expect(described_class.peak_hours?).to be false
      end

      it 'returns false at 00:00 UTC' do
        frozen = Time.utc(2026, 3, 21, 0, 0, 0)
        allow(Time).to receive(:now).and_return(frozen)
        expect(described_class.peak_hours?).to be false
      end
    end

    context 'with custom peak_hours_utc setting' do
      it 'uses the configured range' do
        Legion::Settings[:llm][:scheduling] = { enabled: true, peak_hours_utc: '9-17' }
        frozen = Time.utc(2026, 3, 21, 12, 0, 0)
        allow(Time).to receive(:now).and_return(frozen)
        expect(described_class.peak_hours?).to be true
      end

      it 'falls back to default on invalid format' do
        Legion::Settings[:llm][:scheduling] = { enabled: true, peak_hours_utc: 'invalid' }
        frozen = Time.utc(2026, 3, 21, 16, 0, 0)
        allow(Time).to receive(:now).and_return(frozen)
        expect(described_class.peak_hours?).to be true
      end
    end
  end

  describe '.should_defer?' do
    before do
      Legion::Settings[:llm][:scheduling] = {
        enabled:         true,
        peak_hours_utc:  '14-22',
        defer_intents:   %w[batch background],
        max_defer_hours: 8
      }
    end

    context 'when during peak hours' do
      before do
        frozen = Time.utc(2026, 3, 21, 16, 0, 0)
        allow(Time).to receive(:now).and_return(frozen)
      end

      it 'returns true for a deferrable intent' do
        expect(described_class.should_defer?(intent: :batch)).to be true
      end

      it 'returns true for background intent' do
        expect(described_class.should_defer?(intent: :background)).to be true
      end

      it 'returns false for non-deferrable intent' do
        expect(described_class.should_defer?(intent: :interactive)).to be false
      end

      it 'returns false for :immediate urgency regardless of intent' do
        expect(described_class.should_defer?(intent: :batch, urgency: :immediate)).to be false
      end

      it 'returns false when scheduling is disabled' do
        Legion::Settings[:llm][:scheduling] = { enabled: false }
        expect(described_class.should_defer?(intent: :batch)).to be false
      end
    end

    context 'when outside peak hours' do
      before do
        frozen = Time.utc(2026, 3, 21, 8, 0, 0)
        allow(Time).to receive(:now).and_return(frozen)
      end

      it 'returns false even for deferrable intents' do
        expect(described_class.should_defer?(intent: :batch)).to be false
      end
    end

    context 'with default settings (disabled)' do
      before do
        Legion::Settings[:llm][:scheduling] = {}
      end

      it 'always returns false' do
        frozen = Time.utc(2026, 3, 21, 16, 0, 0)
        allow(Time).to receive(:now).and_return(frozen)
        expect(described_class.should_defer?(intent: :batch)).to be false
      end
    end

    context 'with custom defer_intents from settings' do
      before do
        Legion::Settings[:llm][:scheduling] = {
          enabled:        true,
          defer_intents:  %w[maintenance],
          peak_hours_utc: '14-22'
        }
        frozen = Time.utc(2026, 3, 21, 16, 0, 0)
        allow(Time).to receive(:now).and_return(frozen)
      end

      it 'defers only configured intents' do
        expect(described_class.should_defer?(intent: :maintenance)).to be true
        expect(described_class.should_defer?(intent: :batch)).to be false
      end
    end
  end

  describe '.next_off_peak' do
    before do
      Legion::Settings[:llm][:scheduling] = {
        enabled:         true,
        peak_hours_utc:  '14-22',
        max_defer_hours: 8
      }
    end

    it 'returns a Time object' do
      expect(described_class.next_off_peak).to be_a(Time)
    end

    it 'returns current time (or close to it) when outside peak hours' do
      frozen = Time.utc(2026, 3, 21, 8, 0, 0)
      allow(Time).to receive(:now).and_return(frozen)
      result = described_class.next_off_peak
      expect(result).to be <= frozen + 1
    end

    it 'returns next off-peak window when during peak hours' do
      frozen = Time.utc(2026, 3, 21, 16, 0, 0)
      allow(Time).to receive(:now).and_return(frozen)
      result = described_class.next_off_peak
      # Off-peak starts at 23:00 UTC (peak_end 22 + 1)
      expect(result.hour).to eq(23)
    end

    it 'does not exceed max_defer_hours cap' do
      frozen = Time.utc(2026, 3, 21, 16, 0, 0)
      allow(Time).to receive(:now).and_return(frozen)
      result = described_class.next_off_peak
      cap = frozen + (8 * 3600)
      expect(result).to be <= cap
    end
  end
end
