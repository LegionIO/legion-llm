# frozen_string_literal: true

module Legion
  module LLM
    module Pipeline
      module AuditPublisher
        EXCHANGE    = 'llm.audit'.freeze
        ROUTING_KEY = 'llm.audit.complete'.freeze

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
            if defined?(Legion::Transport) &&
               defined?(Legion::Transport::Messages::Dynamic)
              Legion::Transport::Messages::Dynamic.new(
                function: 'llm_audit',
                opts: event,
                exchange: EXCHANGE,
                routing_key: ROUTING_KEY
              ).publish
            else
              Legion::Logging.debug('audit publish skipped: transport unavailable') if defined?(Legion::Logging)
            end
          rescue StandardError => e
            Legion::Logging.warn("audit publish failed: #{e.message}") if defined?(Legion::Logging)
          end

          event
        rescue StandardError => e
          Legion::Logging.warn("audit build_event failed: #{e.message}") if defined?(Legion::Logging)
          nil
        end
      end
    end
  end
end
