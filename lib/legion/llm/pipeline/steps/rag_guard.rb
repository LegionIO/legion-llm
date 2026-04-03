# frozen_string_literal: true

require 'legion/logging/helper'

module Legion
  module LLM
    module Pipeline
      module Steps
        module RagGuard
          include Legion::Logging::Helper

          def check_rag_faithfulness
            context = @enrichments.dig('rag:context_retrieval', :data, :entries)
            return unless context&.any?
            return unless defined?(Hooks::RagGuard)

            response_text = @raw_response.respond_to?(:content) ? @raw_response.content : @raw_response.to_s

            result = Hooks::RagGuard.check_rag_faithfulness(
              response:  response_text,
              context:   context.map { |e| e[:content] }.join("\n"),
              threshold: 0.7
            )

            return if result.nil? || result[:faithful]

            detail = result[:details] || result[:reason] || 'faithfulness check failed'
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
