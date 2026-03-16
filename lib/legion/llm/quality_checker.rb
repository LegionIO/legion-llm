# frozen_string_literal: true

require 'json'

module Legion
  module LLM
    module QualityChecker
      QualityResult = Struct.new(:passed, :failures)

      REPETITION_MIN_LENGTH = 20
      REPETITION_THRESHOLD  = 3
      DEFAULT_QUALITY_THRESHOLD = 50

      class << self
        def check(response, quality_threshold: DEFAULT_QUALITY_THRESHOLD, json_expected: false, quality_check: nil)
          failures = []
          content = response.content

          failures << :empty_response if content.nil? || content.strip.empty?

          unless failures.include?(:empty_response)
            failures << :too_short if content.length < quality_threshold
            failures << :repetition if repetitive?(content)
            failures << :json_parse_failure if json_expected && !valid_json?(content)
          end

          failures << :custom_check_failed if quality_check.respond_to?(:call) && !quality_check.call(response)

          QualityResult.new(passed: failures.empty?, failures: failures)
        end

        private

        def repetitive?(content)
          return false if content.length < REPETITION_MIN_LENGTH * REPETITION_THRESHOLD

          seen = {}
          (0..(content.length - REPETITION_MIN_LENGTH)).step(REPETITION_MIN_LENGTH) do |i|
            chunk = content[i, REPETITION_MIN_LENGTH]
            seen[chunk] = (seen[chunk] || 0) + 1
            return true if seen[chunk] >= REPETITION_THRESHOLD
          end

          false
        end

        def valid_json?(content)
          ::JSON.parse(content)
          true
        rescue ::JSON::ParserError
          false
        end
      end
    end
  end
end
