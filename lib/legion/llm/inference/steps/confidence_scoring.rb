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

            if @raw_response.respond_to?(:tool_calls) && @raw_response.tool_calls&.any?
              log_step_debug(:confidence_scoring, :skipped, reason: :tool_use_response)
              return
            end

            opts = {
              json_expected:     @request.response_format&.dig(:type) == :json,
              quality_threshold: @request.extra&.dig(:quality_threshold),
              confidence_score:  @request.extra&.dig(:confidence_score),
              confidence_bands:  @request.extra&.dig(:confidence_bands)
            }.compact

            @confidence_score = Quality::Confidence::Scorer.score(@raw_response, **opts)
            (@enrichments ||= {})['confidence:score'] = @confidence_score.to_h
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
            handle_low_confidence if low_confidence?(@confidence_score)
          rescue StandardError => e
            @warnings << "confidence_scoring error: #{e.message}"
            handle_exception(e, level: :warn, operation: 'llm.pipeline.steps.confidence_scoring')
            @confidence_score = nil
          end

          private

          def low_confidence?(score)
            %i[very_low low].include?(score.band)
          end

          def handle_low_confidence
            log.warn(
              "[llm][steps][confidence_scoring] action=low_confidence request_id=#{@request&.id || 'none'} " \
              "score=#{@confidence_score.score.round(3)} band=#{@confidence_score.band} " \
              "source=#{@confidence_score.source} provider=#{@resolved_provider || 'none'} model=#{@resolved_model || 'none'}"
            )
            warning = {
              type:   :low_confidence,
              score:  @confidence_score.score,
              band:   @confidence_score.band,
              source: @confidence_score.source
            }
            @warnings << warning
            @audit[:'confidence:action'] = {
              outcome:     :warning,
              detail:      "low confidence band=#{@confidence_score.band}",
              data:        warning,
              duration_ms: 0,
              timestamp:   Time.now
            }
            @timeline.record(
              category: :quality, key: 'confidence:action',
              direction: :internal,
              detail: "low confidence band=#{@confidence_score.band}",
              from: 'confidence_scoring', to: 'pipeline'
            )
          end
        end
      end
    end
  end
end
