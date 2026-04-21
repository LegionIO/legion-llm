# frozen_string_literal: true

require 'legion/logging/helper'

module Legion
  module LLM
    # Computes a Score for an LLM response using available signals.
    #
    # Strategy selection (in priority order):
    #   1. logprobs  — native model confidence from token log-probabilities (when available)
    #   2. caller    — caller-provided score passed via options[:confidence_score]
    #   3. heuristic — derived from response content characteristics
    #
    # Band boundaries are read from Legion::Settings[:llm][:confidence][:bands] when
    # Legion::Settings is available, otherwise the DEFAULT_BANDS constants are used.
    # Per-call overrides can be passed as options[:confidence_bands].
    module Quality
      module Confidence
        module Scorer
          extend Legion::Logging::Helper

      # Default band boundaries. Keys are the *lower* boundary of that band name:
      #   score <  :low       -> :very_low
      #   score <  :medium    -> :low
      #   score <  :high      -> :medium
      #   score <  :very_high -> :high
      #   score >= :very_high -> :very_high
      DEFAULT_BANDS = {
        low:       0.3,
        medium:    0.5,
        high:      0.7,
        very_high: 0.9
      }.freeze

      # Penalty weights used in heuristic scoring.
      HEURISTIC_WEIGHTS = {
        refusal:            -0.8,
        empty:              -1.0,
        truncated:          -0.4,
        repetition:         -0.5,
        json_parse_failure: -0.6,
        too_short:          -0.3
      }.freeze

      # Bonus applied when structured output parse succeeds.
      STRUCTURED_OUTPUT_BONUS = 0.1

      # Hedging language patterns that reduce confidence.
      HEDGING_PATTERNS = [
        /\b(?:I think|I believe|I'm not sure|I'm uncertain|it seems|it appears|maybe|perhaps|possibly|probably|I guess|I assume)\b/i,
        /\bnot (?:certain|sure|definite|confirmed)\b/i,
        /\bunclear\b/i,
        /\bcould be\b/i
      ].freeze

      class << self
        # Compute a Score for the given raw_response.
        #
        # raw_response - the RubyLLM response object (must respond to #content)
        # options      - Hash:
        #   :confidence_score  - Float  caller-provided score (bypasses heuristics)
        #   :confidence_bands  - Hash   per-call band overrides
        #   :json_expected     - Boolean whether JSON output was expected
        #   :quality_result    - QualityResult from QualityChecker (optional, avoids re-running checks)
        #
        # Returns a Score.
        def score(raw_response, **options)
          bands = resolve_bands(options[:confidence_bands])

          if (caller_score = options[:confidence_score])
            return Score.build(
              score:   caller_score.to_f,
              bands:   bands,
              source:  :caller_provided,
              signals: { caller_provided: caller_score.to_f }
            )
          end

          if (lp = extract_logprobs(raw_response))
            return Score.build(
              score:   lp,
              bands:   bands,
              source:  :logprobs,
              signals: { avg_logprob: lp }
            )
          end

          heuristic_score(raw_response, bands: bands, options: options)
        end

        private

        # Resolve band configuration.  Per-call overrides win, then settings,
        # then DEFAULT_BANDS.
        def resolve_bands(per_call_override)
          base = settings_bands
          return base.merge(per_call_override) if per_call_override.is_a?(Hash)

          base
        end

        def settings_bands
          return DEFAULT_BANDS unless defined?(Legion::Settings)

          raw = Legion::Settings[:llm]
          return DEFAULT_BANDS unless raw.is_a?(Hash)

          conf = raw.dig(:confidence, :bands)
          return DEFAULT_BANDS unless conf.is_a?(Hash)

          DEFAULT_BANDS.merge(conf.transform_keys(&:to_sym))
        end

        # Attempt to derive a score from logprobs attached to the response.
        # RubyLLM does not currently expose logprobs in its standard interface,
        # but some providers return them in extra metadata.  We probe the response
        # object defensively to avoid unexpected-message errors from test doubles.
        def extract_logprobs(raw_response)
          lp = probe_logprobs(raw_response)
          return nil unless lp.is_a?(Array) && !lp.empty?

          # lp is expected to be an array of token log-probability floats (negative values).
          avg_lp = lp.sum.to_f / lp.size
          # Convert average log-probability to a probability-like score in [0, 1].
          # avg_lp is in (-inf, 0]; e^0 = 1.0 (perfect), e^(-5) ≈ 0.007 (very uncertain).
          # We clamp at -5 so very negative values still map to > 0.
          Math.exp([avg_lp, -5.0].max)
        rescue StandardError => e
          handle_exception(e, level: :debug, operation: 'llm.confidence_scorer.extract_logprobs')
          nil
        end

        # Safely probe a response object for logprobs.
        # Checks method_defined? on the concrete class first (not via stubs or method_missing)
        # to avoid triggering MockExpectationError on RSpec test doubles.
        def probe_logprobs(raw_response)
          klass = raw_response.class
          lp = raw_response.logprobs if klass.method_defined?(:logprobs)
          lp ||= raw_response.metadata&.dig(:logprobs) if klass.method_defined?(:metadata)
          lp
        rescue StandardError => e
          handle_exception(e, level: :debug, operation: 'llm.confidence_scorer.probe_logprobs')
          nil
        end

        def heuristic_score(raw_response, bands:, options:)
          signals  = {}
          penalty  = 0.0
          content  = raw_response.respond_to?(:content) ? raw_response.content.to_s : ''

          # Use pre-computed QualityResult when available to avoid duplicate work.
          quality_result = options[:quality_result]

          if content.strip.empty?
            signals[:empty] = true
            penalty += HEURISTIC_WEIGHTS[:empty].abs
          else
            failures = quality_result ? quality_result.failures : detect_failures(content, options)

            failures.each do |failure|
              weight = HEURISTIC_WEIGHTS[failure]
              next unless weight

              signals[failure] = true
              penalty += weight.abs
            end

            hedges = count_hedges(content)
            if hedges.positive?
              hedge_penalty = [hedges * 0.05, 0.3].min
              signals[:hedging] = hedges
              penalty += hedge_penalty
            end

            if options[:json_expected] && !failures.include?(:json_parse_failure)
              signals[:structured_output_valid] = true
              penalty -= STRUCTURED_OUTPUT_BONUS
            end
          end

          raw_score = [1.0 - penalty.clamp(0.0, 1.0), 0.0].max
          Score.build(score: raw_score, bands: bands, source: :heuristic, signals: signals)
        end

        def detect_failures(content, options)
          return [] if content.strip.empty?

          failures = []
          threshold = options.fetch(:quality_threshold, Quality::Checker::DEFAULT_QUALITY_THRESHOLD)
          failures << :too_short if content.length < threshold
          failures << :truncated if truncated?(content)
          failures << :refusal   if refusal?(content)
          failures << :repetition if repetitive?(content)
          failures << :json_parse_failure if options[:json_expected] && !valid_json?(content)
          failures
        end

        def truncated?(content)
          return false if content.length < 100

          last_chars = content[-3..]
          last_chars&.match?(/\w{3}\z/) &&
            !content.end_with?('.', '!', '?', '`', '"', "'", ')', ']', '}', "\n")
        end

        def refusal?(content)
          first_line = content.lines.first.to_s
          Quality::Checker::REFUSAL_PATTERNS.any? { |pat| first_line.match?(pat) }
        end

        def repetitive?(content)
          return false if content.length < Quality::Checker::REPETITION_MIN_LENGTH * Quality::Checker::REPETITION_THRESHOLD

          seen = {}
          step = Quality::Checker::REPETITION_MIN_LENGTH
          (0..(content.length - step)).step(step) do |i|
            chunk = content[i, step]
            seen[chunk] = (seen[chunk] || 0) + 1
            return true if seen[chunk] >= Quality::Checker::REPETITION_THRESHOLD
          end
          false
        end

        def valid_json?(content)
          ::JSON.parse(content)
          true
        rescue ::JSON::ParserError
          false
        end

        def count_hedges(content)
          HEDGING_PATTERNS.sum { |pat| content.scan(pat).size }
        end
      end
        end
      end
    end
  end
end
