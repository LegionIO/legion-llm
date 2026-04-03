# frozen_string_literal: true

require 'legion/logging/helper'

module Legion
  module LLM
    module Pipeline
      module Steps
        module KnowledgeCapture
          include Legion::Logging::Helper

          def step_knowledge_capture
            response = current_response
            request = @request
            enrichments = @enrichments
            local_enabled = local_capture_enabled?

            Thread.new do
              if defined?(Legion::Extensions::Apollo::Helpers::Writeback)
                Legion::Extensions::Apollo::Helpers::Writeback.evaluate_and_route(
                  request:     request,
                  response:    response,
                  enrichments: enrichments
                )
              end

              ingest_to_local(response: response) if local_enabled
            rescue StandardError => e
              handle_exception(e, level: :warn, operation: 'llm.pipeline.steps.knowledge_capture.async')
            end

            @timeline.record(
              category: :knowledge, key: 'knowledge:capture',
              direction: :outbound, detail: 'knowledge capture dispatched async',
              from: 'pipeline', to: 'apollo'
            )
          rescue StandardError => e
            @warnings << "knowledge_capture error: #{e.message}"
            handle_exception(e, level: :warn, operation: 'llm.pipeline.steps.knowledge_capture')
          end

          private

          def local_capture_enabled?
            defined?(::Legion::Apollo::Local) && ::Legion::Apollo::Local.started?
          rescue StandardError => e
            handle_exception(e, level: :debug, operation: 'llm.pipeline.steps.knowledge_capture.local_capture_enabled')
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
            handle_exception(e, level: :warn, operation: 'llm.pipeline.steps.knowledge_capture.ingest_local')
          end
        end
      end
    end
  end
end
