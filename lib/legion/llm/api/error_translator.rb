# frozen_string_literal: true

require 'legion/logging/helper'

module Legion
  module LLM
    module API
      # G14 / D-G: Maps LLM routing errors to HTTP responses.
      #
      # NoLaneAvailable  → 400  (filters excluded everything; caller can fix the request)
      # EscalationExhausted → 503 + Retry-After (tried lanes, all failed; transient upstream degradation)
      # InvalidHeader    → 400  (x-legion-* header carries unrecognized value; caller can fix)
      #
      # Included into API Helpers so every inference route gets the mapping without
      # duplicating rescue clauses. Must be included BEFORE the route-level rescue
      # for StandardError so callers see the typed 400/503 rather than a 500.
      module ErrorTranslator
        extend Legion::Logging::Helper
        include Legion::Logging::Helper

        def translate_no_lane_available(error, operation:, **)
          handle_exception(error, level: :warn, handled: true, operation: operation)
          body = {
            error: {
              type:    'no_lane_available',
              message: error.message,
              filters: error.respond_to?(:filters) ? error.filters : {}
            }
          }
          content_type :json
          status 400
          Legion::JSON.dump(body)
        end

        def translate_escalation_exhausted(error, operation:, **)
          handle_exception(error, level: :warn, handled: true, operation: operation)
          # opus M5: read from settings; no inline || literal at the read site.
          retry_after = Legion::Settings[:llm][:api][:escalation_exhausted_retry_after]
          headers 'Retry-After' => retry_after.to_s
          body = {
            error: {
              type:              'escalation_exhausted',
              message:           error.message,
              attempts:          error.respond_to?(:attempts) ? error.attempts : 0,
              tried_lanes_count: Array(error.respond_to?(:tried_lanes) ? error.tried_lanes : []).size
            }
          }
          content_type :json
          status 503
          Legion::JSON.dump(body)
        end

        def translate_invalid_header(error, operation:, **)
          handle_exception(error, level: :warn, handled: true, operation: operation)
          body = {
            error: {
              type:    'invalid_header',
              message: error.message,
              header:  error.respond_to?(:header) ? error.header : nil,
              got:     error.respond_to?(:got)    ? error.got    : nil,
              valid:   error.respond_to?(:valid)  ? error.valid  : []
            }.compact
          }
          content_type :json
          status 400
          Legion::JSON.dump(body)
        end
      end
    end
  end
end
