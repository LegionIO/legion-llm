# frozen_string_literal: true

module Legion
  module LLM
    module Pipeline
      module Steps
        module KnowledgeCapture
          def step_knowledge_capture
            return unless defined?(Legion::Extensions::Apollo::Helpers::Writeback)

            response = current_response
            return unless response

            Legion::Extensions::Apollo::Helpers::Writeback.evaluate_and_route(
              request:     @request,
              response:    response,
              enrichments: @enrichments
            )

            @timeline.record(
              category: :knowledge, key: 'knowledge:capture',
              direction: :outbound, detail: 'evaluated writeback to apollo',
              from: 'pipeline', to: 'apollo'
            )
          rescue StandardError => e
            @warnings << "knowledge_capture error: #{e.message}"
          end
        end
      end
    end
  end
end
