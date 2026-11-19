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

          def step_knowledge_capture(async: true)
            unless knowledge_capture_enabled?
              log_step_debug(:knowledge_capture, :skipped, reason: :disabled)
              return
            end

            response = current_response
            request = @request
            enrichments = @enrichments
            writeback_enabled = knowledge_capture_writeback_enabled? && !defined?(Legion::Extensions::Apollo::Helpers::Writeback).nil?
            local_enabled = local_capture_enabled?
            unless writeback_enabled || local_enabled
              log_step_debug(:knowledge_capture, :skipped, reason: :no_targets)
              return
            end

            content_chars = response&.message&.dig(:content).to_s.length
            log_step_info(
              :knowledge_capture,
              :dispatch_async,
              writeback_enabled:   writeback_enabled,
              local_enabled:       local_enabled,
              writeback_available: defined?(Legion::Extensions::Apollo::Helpers::Writeback),
              response_chars:      content_chars
            )

            capture = proc do
              if writeback_enabled && defined?(Legion::Extensions::Apollo::Helpers::Writeback)
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

            accepted = async ? Background.post(workload: :knowledge_capture, &capture) : capture.call
            if async && !accepted
              @timeline.record(category: :knowledge, key: 'knowledge:capture', direction: :outbound,
                               detail: 'optional knowledge capture skipped: background executor unavailable',
                               from: 'pipeline', to: 'apollo', data: { status: :skipped })
              return false
            end

            @timeline.record(
              category: :knowledge, key: 'knowledge:capture',
              direction: :outbound, detail: async ? 'knowledge capture dispatched async' : 'knowledge capture completed',
              from: 'pipeline', to: 'apollo'
            )
          rescue StandardError => e
            @warnings << "knowledge_capture error: #{e.message}"
            handle_exception(e, level: :warn, operation: 'llm.pipeline.steps.knowledge_capture')
          end

          private

          def knowledge_capture_requested?
            knowledge_capture_enabled? &&
              ((knowledge_capture_writeback_enabled? && defined?(Legion::Extensions::Apollo::Helpers::Writeback)) || local_capture_enabled?)
          end

          def knowledge_capture_enabled?
            knowledge_capture_setting(:enabled) == true
          end

          def knowledge_capture_writeback_enabled?
            knowledge_capture_setting(:writeback_enabled) == true
          end

          def knowledge_capture_local_ingest_enabled?
            knowledge_capture_setting(:local_ingest_enabled) == true
          end

          def knowledge_capture_setting(key)
            Legion::LLM::Settings.resolve(:knowledge_capture, key)
          end

          def local_capture_enabled?
            return false unless knowledge_capture_local_ingest_enabled?

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

            content = content[0, knowledge_capture_setting(:max_content_chars)]

            model = response.routing[:model].to_s
            tags  = ['llm_response', model].reject(&:empty?)
            log_step_debug(:knowledge_capture, :local_ingest, content_chars: content.length, tag_count: tags.size)

            ::Legion::Apollo::Local.ingest(
              content:        content,
              tags:           tags,
              source_channel: 'llm_pipeline',
              confidence:     knowledge_capture_setting(:confidence)
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
