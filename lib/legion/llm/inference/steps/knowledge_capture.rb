# frozen_string_literal: true

require 'legion/logging/helper'
require_relative 'logging'

module Legion
  module LLM
    module Inference
      module Steps
        module KnowledgeCapture
          include Legion::Logging::Helper
          include Steps::Logging

          def step_knowledge_capture
            response = current_response
            request = @request
            enrichments = @enrichments
            local_enabled = local_capture_enabled?
            log_step_debug(
              :knowledge_capture,
              :dispatch_async,
              local_enabled:       local_enabled,
              writeback_available: defined?(Legion::Extensions::Apollo::Helpers::Writeback)
            )

            Thread.new do
              if defined?(Legion::Extensions::Apollo::Helpers::Writeback)
                log_step_debug(:knowledge_capture, :writeback_route)
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
            handle_exception(e, level: :warn, operation: 'llm.pipeline.steps.knowledge_capture.local_capture_enabled')
            false
          end

          def ingest_to_local(response:)
            unless response
              log_step_debug(:knowledge_capture, :local_ingest_skipped, reason: :no_response)
              return
            end

            content = response.message[:content].to_s
            if content.empty?
              log_step_debug(:knowledge_capture, :local_ingest_skipped, reason: :empty_content)
              return
            end

            model = response.routing[:model].to_s
            tags  = ['llm_response', model].reject(&:empty?)
            log_step_debug(:knowledge_capture, :local_ingest, content_chars: content.length, tag_count: tags.size)

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
