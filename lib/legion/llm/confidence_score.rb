# frozen_string_literal: true

module Legion
  module LLM
    # Immutable value object representing a scored confidence level for an LLM response.
    #
    # score - Float in [0.0, 1.0]
    # band  - Symbol: :very_low, :low, :medium, :high, :very_high
    # source - Symbol: :heuristic, :logprobs, :caller_provided
    # signals - Hash of contributing signals and their raw values (informational)
    ConfidenceScore = ::Data.define(:score, :band, :source, :signals) do
      def self.build(score:, bands:, source: :heuristic, signals: {})
        clamped = score.to_f.clamp(0.0, 1.0)
        new(
          score:   clamped,
          band:    classify(clamped, bands),
          source:  source,
          signals: signals
        )
      end

      # Returns true when the band is at or above the given band name.
      def at_least?(band_name)
        Legion::LLM::ConfidenceScore::BAND_ORDER.index(band) >= Legion::LLM::ConfidenceScore::BAND_ORDER.index(band_name.to_sym)
      end

      def to_h
        { score: score, band: band, source: source, signals: signals }
      end

      class << self
        private

        def classify(score, bands)
          return :very_low  if score < bands.fetch(:low,       0.3)
          return :low       if score < bands.fetch(:medium,    0.5)
          return :medium    if score < bands.fetch(:high,      0.7)
          return :high      if score < bands.fetch(:very_high, 0.9)

          :very_high
        end
      end
    end

    # Band ordering from lowest to highest — defined outside the Data.define block
    # so it is accessible as Legion::LLM::ConfidenceScore::BAND_ORDER.
    ConfidenceScore::BAND_ORDER = %i[very_low low medium high very_high].freeze
  end
end
