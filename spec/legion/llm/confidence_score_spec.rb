# frozen_string_literal: true

require 'spec_helper'
require 'legion/llm/confidence_score'

RSpec.describe Legion::LLM::ConfidenceScore do
  let(:default_bands) do
    { low: 0.3, medium: 0.5, high: 0.7, very_high: 0.9 }
  end

  describe '.build' do
    it 'clamps score to [0.0, 1.0]' do
      score = described_class.build(score: 1.5, bands: default_bands)
      expect(score.score).to eq(1.0)

      score = described_class.build(score: -0.5, bands: default_bands)
      expect(score.score).to eq(0.0)
    end

    it 'assigns :very_low band below low boundary' do
      score = described_class.build(score: 0.1, bands: default_bands)
      expect(score.band).to eq(:very_low)
    end

    it 'assigns :low band between low and medium boundaries' do
      score = described_class.build(score: 0.4, bands: default_bands)
      expect(score.band).to eq(:low)
    end

    it 'assigns :medium band between medium and high boundaries' do
      score = described_class.build(score: 0.6, bands: default_bands)
      expect(score.band).to eq(:medium)
    end

    it 'assigns :high band between high and very_high boundaries' do
      score = described_class.build(score: 0.8, bands: default_bands)
      expect(score.band).to eq(:high)
    end

    it 'assigns :very_high band at or above very_high boundary' do
      score = described_class.build(score: 0.95, bands: default_bands)
      expect(score.band).to eq(:very_high)
    end

    it 'assigns :very_high band exactly at 1.0' do
      score = described_class.build(score: 1.0, bands: default_bands)
      expect(score.band).to eq(:very_high)
    end

    it 'defaults source to :heuristic' do
      score = described_class.build(score: 0.5, bands: default_bands)
      expect(score.source).to eq(:heuristic)
    end

    it 'accepts custom source' do
      score = described_class.build(score: 0.8, bands: default_bands, source: :logprobs)
      expect(score.source).to eq(:logprobs)
    end

    it 'stores signals hash' do
      score = described_class.build(score: 0.6, bands: default_bands, signals: { refusal: true })
      expect(score.signals).to eq({ refusal: true })
    end

    it 'respects custom band boundaries' do
      narrow_bands = { low: 0.1, medium: 0.2, high: 0.3, very_high: 0.4 }
      # 0.35 is >= 0.3 (high boundary) but < 0.4 (very_high boundary) -> :high
      score = described_class.build(score: 0.35, bands: narrow_bands)
      expect(score.band).to eq(:high)
    end
  end

  describe '#at_least?' do
    subject(:score) { described_class.build(score: 0.6, bands: default_bands) }

    it 'returns true for its own band' do
      expect(score.at_least?(:medium)).to be true
    end

    it 'returns true for lower bands' do
      expect(score.at_least?(:very_low)).to be true
      expect(score.at_least?(:low)).to be true
    end

    it 'returns false for higher bands' do
      expect(score.at_least?(:high)).to be false
      expect(score.at_least?(:very_high)).to be false
    end

    it 'accepts string band names' do
      expect(score.at_least?('medium')).to be true
      expect(score.at_least?('high')).to be false
    end
  end

  describe '#to_h' do
    it 'returns a hash with all fields' do
      score = described_class.build(score: 0.75, bands: default_bands, source: :logprobs, signals: { foo: 1 })
      h = score.to_h
      expect(h).to include(score: 0.75, band: :high, source: :logprobs, signals: { foo: 1 })
    end
  end

  describe 'BAND_ORDER' do
    it 'is ordered from lowest to highest' do
      expect(described_class::BAND_ORDER).to eq(%i[very_low low medium high very_high])
    end
  end
end
