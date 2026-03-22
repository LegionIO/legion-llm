# frozen_string_literal: true

module Legion
  module LLM
    module Hooks
      module RagGuard
        class << self
          def check_rag_faithfulness(response:, context:, threshold: nil, evaluators: nil, **)
            return { faithful: true, reason: :eval_unavailable } unless eval_available?

            resolved_threshold = threshold || settings_threshold
            resolved_evaluators = evaluators || settings_evaluators

            scores = {}
            flagged = []

            resolved_evaluators.each do |evaluator_name|
              score = run_evaluator(evaluator_name, response: response, context: context)
              scores[evaluator_name] = score
              flagged << evaluator_name if score < resolved_threshold
            end

            faithful = flagged.empty?
            details = build_details(scores, resolved_threshold, faithful)

            { faithful: faithful, scores: scores, flagged_evaluators: flagged, details: details }
          rescue StandardError => e
            Legion::Logging.warn "RagGuard evaluation error: #{e.message}" if logging_available?
            { faithful: true, reason: :eval_error }
          end

          private

          def eval_available?
            defined?(Legion::Extensions::Eval::Client)
          end

          def logging_available?
            Legion.const_defined?('Logging')
          end

          def settings_threshold
            val = Legion::Settings.dig(:llm, :rag_guard, :threshold) if Legion.const_defined?('Settings')
            val || 0.7
          end

          def settings_evaluators
            val = Legion::Settings.dig(:llm, :rag_guard, :evaluators) if Legion.const_defined?('Settings')
            val || %i[faithfulness rag_relevancy]
          end

          def run_evaluator(evaluator_name, response:, context:)
            client = Legion::Extensions::Eval::Client.new
            result = client.run_evaluation(
              evaluator_name: evaluator_name,
              inputs:         [{ input: context.to_s, output: response.to_s, expected: nil }]
            )
            result.dig(:summary, :avg_score) || 0.0
          rescue StandardError => e
            Legion::Logging.debug("RagGuard evaluator #{evaluator_name} failed: #{e.message}") if defined?(Legion::Logging)
            0.0
          end

          def build_details(scores, threshold, faithful)
            score_parts = scores.map { |k, v| "#{k}=#{v.round(3)}" }.join(', ')
            status = faithful ? 'passed' : 'failed'
            "RAG faithfulness check #{status} (threshold=#{threshold}): #{score_parts}"
          end
        end
      end
    end
  end
end
