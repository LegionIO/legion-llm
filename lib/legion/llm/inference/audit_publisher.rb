# frozen_string_literal: true

require 'legion/logging/helper'
module Legion
  module LLM
    module Inference
      module AuditPublisher
        extend Legion::Logging::Helper

        module_function

        def build_event(request:, response:)
          log.debug("[audit_publisher][build_event] action=build request_id=#{response.request_id} conversation_id=#{response.conversation_id}")

          resp_message = response.message
          msg_content = resp_message.is_a?(Types::Message) ? resp_message.text : resp_message[:content]
          msg_id = resp_message.is_a?(Types::Message) ? resp_message.id : nil
          msg_task_id = resp_message.is_a?(Types::Message) ? resp_message.task_id : nil
          msg_conversation_id = resp_message.is_a?(Types::Message) ? resp_message.conversation_id : nil

          tools_data = Array(response.tools).map do |tc|
            tc.is_a?(Types::ToolCall) ? tc.to_audit_hash : tc
          end

          audit_data = response.audit || {}
          provider_payload = audit_data[:provider_payload] || {}

          event = {
            request_id:       response.request_id,
            conversation_id:  response.conversation_id,
            caller:           response.caller,
            identity:         extract_identity(response.caller),
            routing:          response.routing,
            tokens:           serialize_tokens(response.tokens),
            cost:             response.cost,
            system_prompt:    provider_payload[:system_prompt],
            injected_tools:   provider_payload[:injected_tools],
            enrichments:      compact_enrichments(response.enrichments),
            audit:            audit_data.except(:provider_payload),
            timeline:         compact_timeline(response.timeline),
            classification:   response.classification,
            tracing:          response.tracing,
            messages:         current_turn_messages(request.messages),
            response_content: msg_content,
            tools_used:       tools_data,
            timestamp:        Time.now,
            request_type:     request.respond_to?(:request_type) ? request.request_type : 'chat',
            tier:             response.routing.is_a?(Hash) ? response.routing[:tier] : nil,
            message_context:  build_message_context(request: request, response: response)
          }
          event[:message_id] = msg_id if msg_id
          event[:task_id] = msg_task_id if msg_task_id
          event[:message_conversation_id] = msg_conversation_id if msg_conversation_id
          event
        end

        def publish(request:, response:)
          event = build_event(request: request, response: response)
          Legion::LLM::Audit.emit_prompt(event)
          event
        rescue StandardError => e
          handle_exception(e, level: :warn)
          nil
        end

        def extract_identity(caller)
          return nil unless caller.is_a?(Hash)

          rb = caller[:requested_by] || caller['requested_by']
          return nil unless rb.is_a?(Hash)

          {
            identity:   rb[:identity] || rb['identity'],
            type:       rb[:type] || rb['type'],
            credential: rb[:credential] || rb['credential']
          }.compact
        end

        def serialize_tokens(tokens)
          return tokens.to_h if tokens.respond_to?(:to_h) && !tokens.is_a?(Hash)
          return tokens if tokens.is_a?(Hash)

          {}
        end

        def compact_enrichments(enrichments)
          return {} unless enrichments.is_a?(Hash)

          enrichments.transform_values do |v|
            next v unless v.is_a?(Hash)

            summary = { content: v[:content], timestamp: v[:timestamp] }
            data = v[:data]
            next summary unless data.is_a?(Hash)

            compacted = data.transform_values do |dv|
              dv.is_a?(Array) && dv.size > 1 ? dv.last : dv
            end
            summary.merge(data: compacted)
          end
        end

        def compact_timeline(timeline)
          return [] unless timeline.is_a?(Array)

          timeline.select do |event|
            key = (event[:key] || event['key']).to_s
            key.start_with?('provider:') || key.start_with?('escalation:') || key.start_with?('tool:execute:')
          end
        end

        def current_turn_messages(messages)
          return messages unless messages.is_a?(Array)

          max = audit_max_messages
          return messages if messages.size <= max

          messages.last(max)
        end

        def audit_max_messages
          return 20 unless defined?(Legion::Settings)

          Legion::Settings[:llm].dig(:compliance, :audit_max_messages) || 20
        rescue StandardError
          20
        end

        def build_message_context(response:, **)
          {
            request_id:      response.request_id,
            conversation_id: response.conversation_id
          }.compact
        end
      end
    end
  end
end
