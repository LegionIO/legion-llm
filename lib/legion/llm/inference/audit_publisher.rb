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

          event = {
            request_id:       response.request_id,
            conversation_id:  response.conversation_id,
            caller:           response.caller,
            routing:          response.routing,
            tokens:           response.tokens,
            cost:             response.cost,
            enrichments:      response.enrichments,
            audit:            response.audit,
            timeline:         response.timeline,
            timestamps:       response.timestamps,
            classification:   response.classification,
            tracing:          response.tracing,
            messages:         request.messages,
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
