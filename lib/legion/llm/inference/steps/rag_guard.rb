# frozen_string_literal: true

require 'legion/logging/helper'
require_relative 'logging'

module Legion
  module LLM
    module Inference
      module Steps
        module RagGuard
          include Legion::Logging::Helper
          include Steps::Logging

          def check_rag_faithfulness
            context = @enrichments.dig('rag:context_retrieval', :data, :entries)
            unless context&.any?
              log_step_debug(:rag_guard, :skipped, reason: :no_context)
              return
            end

            unless defined?(Hooks::RagGuard)
              log.warn('[rag_guard] RAG context present but no Hooks::RagGuard registered — faithfulness check skipped')
              log_step_debug(:rag_guard, :skipped, reason: :hook_missing, context_count: context.size)
              return
            end

            response_text = @raw_response.respond_to?(:content) ? @raw_response.content : @raw_response.to_s
            log_step_debug(:rag_guard, :checking, context_count: context.size, response_chars: response_text.length)

            result = Hooks::RagGuard.check_rag_faithfulness(
              response:  response_text,
              context:   context.map { |e| e[:content] }.join("\n"),
              threshold: rag_faithfulness_threshold
            )

            unless result.is_a?(Hash)
              log_step_debug(:rag_guard, :skipped, reason: :unexpected_result)
              return
            end

            if result[:faithful] == true
              record_rag_faithfulness_audit(:success, result)
              log_step_debug(:rag_guard, :passed)
              return
            end

            detail = result[:details] || result[:reason] || 'faithfulness check failed'
            log.warn("[rag_guard] RAG faithfulness failure: #{detail}")
            log_step_info(:rag_guard, :blocked, reason_chars: detail.to_s.length)
            @warnings << { type: :rag_faithfulness_failure, message: detail, result: result }
            record_rag_faithfulness_audit(:failure, result, detail: detail)
            @timeline.record(
              category: :quality, key: 'rag:faithfulness_failure',
              direction: :internal, detail: detail,
              from: 'rag_guard', to: 'pipeline'
            )
            return unless rag_block_on_failure?

            raise Legion::LLM::PipelineError.new("RAG faithfulness failed: #{detail}", step: :rag_guard)
          rescue Legion::LLM::PipelineError
            raise
          rescue StandardError => e
            @warnings << "RagGuard error: #{e.message}"
            handle_exception(e, level: :warn, operation: 'llm.pipeline.steps.rag_guard')
          end

          private

          def rag_guard_settings
            Legion::LLM::Settings.value(:rag_guard, default: {})
          rescue StandardError => e
            handle_exception(e, level: :debug, operation: 'llm.pipeline.steps.rag_guard.settings')
            {}
          end

          def rag_guard_setting(key, default)
            value = Legion::LLM::Settings.config_value(rag_guard_settings, key)
            value.nil? ? default : value
          end

          def rag_block_on_failure?
            rag_guard_setting(:block_on_failure, true)
          end

          def rag_faithfulness_threshold
            rag_guard_setting(:threshold, 0.7)
          end

          def record_rag_faithfulness_audit(outcome, result, detail: nil)
            @audit[:'rag:faithfulness'] = {
              outcome:     outcome,
              detail:      detail || result[:details] || result[:reason] || outcome.to_s,
              data:        result,
              duration_ms: 0,
              timestamp:   Time.now
            }
          end
        end
      end
    end
  end
end
