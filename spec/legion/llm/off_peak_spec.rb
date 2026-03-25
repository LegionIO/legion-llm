# frozen_string_literal: true

require 'spec_helper'
require 'legion/llm/off_peak'

RSpec.describe Legion::LLM::OffPeak do
  describe '.peak_hour?' do
    context 'with default peak range (14-22 UTC)' do
      it 'returns true during peak hours (16:00 UTC)' do
        frozen = Time.utc(2026, 3, 21, 16, 0, 0)
        allow(Time).to receive(:now).and_return(frozen)
        expect(described_class.peak_hour?).to be true
      end

      it 'returns true at the start of peak (14:00 UTC)' do
        frozen = Time.utc(2026, 3, 21, 14, 0, 0)
        expect(described_class.peak_hour?(frozen)).to be true
      end

      it 'returns true at the end of peak (22:00 UTC)' do
        frozen = Time.utc(2026, 3, 21, 22, 0, 0)
        expect(described_class.peak_hour?(frozen)).to be true
      end

      it 'returns false before peak hours (08:00 UTC)' do
        frozen = Time.utc(2026, 3, 21, 8, 0, 0)
        expect(described_class.peak_hour?(frozen)).to be false
      end

      it 'returns false at midnight UTC' do
        frozen = Time.utc(2026, 3, 21, 0, 0, 0)
        expect(described_class.peak_hour?(frozen)).to be false
      end

      it 'returns false at 23:00 UTC (after peak end)' do
        frozen = Time.utc(2026, 3, 21, 23, 0, 0)
        expect(described_class.peak_hour?(frozen)).to be false
      end
    end
  end

  describe '.should_defer?' do
    context 'during peak hours' do
      let(:peak_time) { Time.utc(2026, 3, 21, 16, 0, 0) }

      before do
        allow(Time).to receive(:now).and_return(peak_time)
        Legion::Settings[:llm][:scheduling] = { enabled: true }
      end

      it 'returns true for normal priority' do
        expect(described_class.should_defer?(priority: :normal)).to be true
      end

      it 'returns true for low priority' do
        expect(described_class.should_defer?(priority: :low)).to be true
      end

      it 'returns false for urgent priority' do
        expect(described_class.should_defer?(priority: :urgent)).to be false
      end

      it 'returns true when no priority is given (defaults to :normal)' do
        expect(described_class.should_defer?).to be true
      end
    end

    context 'outside peak hours' do
      let(:off_peak_time) { Time.utc(2026, 3, 21, 8, 0, 0) }

      before { allow(Time).to receive(:now).and_return(off_peak_time) }

      it 'returns false even for normal priority' do
        expect(described_class.should_defer?(priority: :normal)).to be false
      end

      it 'returns false for low priority' do
        expect(described_class.should_defer?(priority: :low)).to be false
      end
    end
  end

  describe '.next_off_peak' do
    it 'returns a Time object' do
      expect(described_class.next_off_peak).to be_a(Time)
    end

    it 'returns the current time when already off-peak (before peak)' do
      frozen = Time.utc(2026, 3, 21, 8, 0, 0)
      result = described_class.next_off_peak(frozen)
      expect(result).to eq(frozen)
    end

    it 'returns the current time when already off-peak (at midnight)' do
      frozen = Time.utc(2026, 3, 21, 0, 0, 0)
      result = described_class.next_off_peak(frozen)
      expect(result).to eq(frozen)
    end

    it 'returns the first off-peak hour when during peak' do
      frozen = Time.utc(2026, 3, 21, 16, 0, 0)
      result = described_class.next_off_peak(frozen)
      expect(result.hour).to eq(23)
      expect(result.min).to eq(0)
    end

    it 'returns the next off-peak hour when at the last peak hour (22:00 UTC)' do
      frozen = Time.utc(2026, 3, 21, 22, 0, 0)
      result = described_class.next_off_peak(frozen)
      expect(result.hour).to eq(23)
    end

    it 'returns a time on the same day as the reference time' do
      frozen = Time.utc(2026, 3, 21, 16, 0, 0)
      result = described_class.next_off_peak(frozen)
      expect(result.day).to eq(frozen.day)
    end
  end
end
