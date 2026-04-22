# frozen_string_literal: true

require 'legion/logging/helper'

module Legion
  module LLM
    module Inference
      module Steps
        module ConfidenceScoring
          include Legion::Logging::Helper

          def step_confidence_scoring
            return unless @raw_response

            opts = {
              json_expected:     @request.response_format&.dig(:type) == :json,
              quality_threshold: @request.extra&.dig(:quality_threshold),
              confidence_score:  @request.extra&.dig(:confidence_score),
              confidence_bands:  @request.extra&.dig(:confidence_bands)
            }.compact

            @confidence_score = Quality::Confidence::Scorer.score(@raw_response, **opts)

            @timeline.record(
              category: :internal, key: 'confidence:scored',
              direction: :internal,
              detail: "score=#{@confidence_score.score.round(3)} band=#{@confidence_score.band} source=#{@confidence_score.source}",
              from: 'pipeline', to: 'pipeline'
            )
          rescue StandardError => e
            @warnings << "confidence_scoring error: #{e.message}"
            handle_exception(e, level: :warn, operation: 'llm.pipeline.steps.confidence_scoring')
            @confidence_score = nil
          end
        end
      end
    end
  end
end
