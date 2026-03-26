# frozen_string_literal: true

module Legion
  module LLM
    module Pipeline
      module Steps
        module KnowledgeCapture
          def step_knowledge_capture
            response = current_response

            if defined?(Legion::Extensions::Apollo::Helpers::Writeback)
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
            end

            ingest_to_local(response: response) if local_capture_enabled?
          rescue StandardError => e
            @warnings << "knowledge_capture error: #{e.message}"
          end

          private

          def local_capture_enabled?
            defined?(::Legion::Apollo::Local) && ::Legion::Apollo::Local.started?
          rescue StandardError
            false
          end

          def ingest_to_local(response:)
            return unless response

            content = response.message[:content].to_s
            return if content.empty?

            model = response.routing[:model].to_s
            tags  = ['llm_response', model].reject(&:empty?)

            ::Legion::Apollo::Local.ingest(
              content:        content,
              tags:           tags,
              source_channel: 'llm_pipeline',
              confidence:     0.8
            )
          rescue StandardError => e
            @warnings << "local_knowledge_capture error: #{e.message}"
          end
        end
      end
    end
  end
end
