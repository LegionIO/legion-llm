# frozen_string_literal: true

require 'legion/logging/helper'
module Legion
  module LLM
    module Pipeline
      module AuditPublisher
        extend Legion::Logging::Helper

        EXCHANGE    = 'llm.audit'
        ROUTING_KEY = 'llm.audit.complete'

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
            timestamp:        Time.now
          }
        end

        def publish(request:, response:)
          event = build_event(request: request, response: response)

          begin
            if defined?(Legion::Transport)
              require 'legion/llm/transport/exchanges/audit'
              require 'legion/llm/transport/messages/audit_event'
              Legion::LLM::Transport::Messages::AuditEvent.new(**event).publish
            else
              log.debug('audit publish skipped: transport unavailable')
            end
          rescue StandardError => e
            handle_exception(e, level: :warn)
          end

          event
        rescue StandardError => e
          handle_exception(e, level: :warn)
          nil
        end
      end
    end
  end
end
