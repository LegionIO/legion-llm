# frozen_string_literal: true

require 'legion/logging/helper'
require_relative 'logging'

module Legion
  module LLM
    module Inference
      module Steps
        module ConfidenceScoring
          include Legion::Logging::Helper
          include Steps::Logging

          def step_confidence_scoring
            unless @raw_response
              log_step_debug(:confidence_scoring, :skipped, reason: :no_response)
              return
            end

            opts = {
              json_expected:     @request.response_format&.dig(:type) == :json,
              quality_threshold: @request.extra&.dig(:quality_threshold),
              confidence_score:  @request.extra&.dig(:confidence_score),
              confidence_bands:  @request.extra&.dig(:confidence_bands)
            }.compact

            @confidence_score = Quality::Confidence::Scorer.score(@raw_response, **opts)
            log_step_debug(
              :confidence_scoring,
              :scored,
              score:  @confidence_score.score.round(3),
              band:   @confidence_score.band,
              source: @confidence_score.source
            )

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
