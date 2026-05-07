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
              threshold: 0.7
            )

            if result.nil? || result[:faithful]
              log_step_debug(:rag_guard, :passed)
              return
            end

            detail = result[:details] || result[:reason] || 'faithfulness check failed'
            log.warn("[rag_guard] RAG faithfulness warning: #{detail}")
            log_step_info(:rag_guard, :warning, reason_chars: detail.to_s.length)
            @warnings << "RAG faithfulness warning: #{detail}"
            @timeline.record(
              category: :quality, key: 'rag:faithfulness_warning',
              direction: :internal, detail: detail,
              from: 'rag_guard', to: 'pipeline'
            )
          rescue StandardError => e
            @warnings << "RagGuard error: #{e.message}"
            handle_exception(e, level: :warn, operation: 'llm.pipeline.steps.rag_guard')
          end
        end
      end
    end
  end
end
