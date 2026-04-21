# frozen_string_literal: true

require 'legion/logging/helper'
module Legion
  module LLM
    module Inference
      module AuditPublisher
        extend Legion::Logging::Helper

        module_function

        def build_event(request:, response:)
          {
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
            response_content: response.message[:content],
            tools_used:       response.tools,
            timestamp:        Time.now,
            request_type:     request.respond_to?(:request_type) ? request.request_type : 'chat',
            tier:             response.routing.is_a?(Hash) ? response.routing[:tier] : nil,
            message_context:  build_message_context(request: request, response: response)
          }
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
