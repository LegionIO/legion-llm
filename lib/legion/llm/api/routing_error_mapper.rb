# frozen_string_literal: true

require 'legion/logging/helper'

module Legion
  module LLM
    module API
      # SSOT v3 §18 / D16 — Maps a Phase 1 Routing::Rejection value to an
      # immutable HTTP response triple (status, headers, body) for one of
      # three API dialects.
      #
      # Responsibilities: status, Retry-After header, and dialect-formatted
      # body ONLY. Performs no logging inside .call, no selection, no retry,
      # and no provider inspection.
      #
      # Body shapes sourced from the existing API surface (read-only reference):
      #   native    { error: { code:, message: } }
      #   openai    { error: { message:, type:, code: } }
      #   anthropic { type: 'error', error: { type:, message: } }
      #
      # Retry-After semantics (D16): routing_too_early_retry_after setting,
      # owned by Legion::LLM::Settings::API. Prefer SettingsState when loaded;
      # fall back to direct bracket access on the configured path.
      module RoutingErrorMapper
        include Legion::Logging::Helper
        extend  Legion::Logging::Helper

        # Immutable HTTP response value object (::Data.define; instances are
        # frozen automatically in Ruby 3.2+).
        Response = ::Data.define(:status, :headers, :body)

        DIALECTS = %i[native openai anthropic].freeze
        private_constant :DIALECTS

        # These three kinds carry a Retry-After header on every dialect.
        RETRY_AFTER_KINDS = %i[too_early service_unavailable attempts_exhausted].freeze
        private_constant :RETRY_AFTER_KINDS

        # §18 status table: { kind => { dialect => HTTP status } }
        #
        # Key divergence: too_early stays 425 for native (Legion-aware clients
        # can distinguish incomplete authority), while compat SDKs see retryable
        # 503 (OpenAI) or 529 (Anthropic).
        STATUS_TABLE = {
          invalid_routing_context: { native: 500, openai: 500, anthropic: 500 },
          invalid_request:         { native: 400, openai: 400, anthropic: 400 },
          policy_denied:           { native: 403, openai: 403, anthropic: 403 },
          failed_dependency:       { native: 424, openai: 424, anthropic: 424 },
          too_early:               { native: 425, openai: 503, anthropic: 529 },
          service_unavailable:     { native: 503, openai: 503, anthropic: 529 },
          context_rejected:        { native: 400, openai: 400, anthropic: 400 },
          attempts_exhausted:      { native: 503, openai: 503, anthropic: 529 },
          stale_selection:         { native: 503, openai: 503, anthropic: 529 }
        }.freeze
        private_constant :STATUS_TABLE

        # Error type / code table per kind.
        #   native_code:    placed in { error: { code: } }
        #   openai_type:    placed in { error: { type: } }
        #   openai_code:    placed in { error: { code: } } (nil = no spec'd code)
        #   anthropic_type: placed in { type: 'error', error: { type: } }
        #
        # D16: native too_early code is 'routing_too_early'; OpenAI too_early
        # code is also 'routing_too_early'.
        TYPE_TABLE = {
          invalid_routing_context: {
            native_code:    'internal_error',
            openai_type:    'server_error',
            openai_code:    nil,
            anthropic_type: 'api_error'
          },
          invalid_request:         {
            native_code:    'invalid_request',
            openai_type:    'invalid_request_error',
            openai_code:    nil,
            anthropic_type: 'invalid_request_error'
          },
          policy_denied:           {
            native_code:    'policy_denied',
            openai_type:    'permission_error',
            openai_code:    nil,
            anthropic_type: 'permission_error'
          },
          failed_dependency:       {
            native_code:    'failed_dependency',
            openai_type:    'server_error',
            openai_code:    nil,
            anthropic_type: 'api_error'
          },
          too_early:               {
            native_code:    'routing_too_early',
            openai_type:    'server_error',
            openai_code:    'routing_too_early',
            anthropic_type: 'overloaded_error'
          },
          service_unavailable:     {
            native_code:    'service_unavailable',
            openai_type:    'server_error',
            openai_code:    nil,
            anthropic_type: 'overloaded_error'
          },
          context_rejected:        {
            native_code:    'context_rejected',
            openai_type:    'invalid_request_error',
            openai_code:    nil,
            anthropic_type: 'invalid_request_error'
          },
          attempts_exhausted:      {
            native_code:    'attempts_exhausted',
            openai_type:    'server_error',
            openai_code:    nil,
            anthropic_type: 'overloaded_error'
          },
          stale_selection:         {
            native_code:    'stale_selection',
            openai_type:    'server_error',
            openai_code:    nil,
            anthropic_type: 'overloaded_error'
          }
        }.freeze
        private_constant :TYPE_TABLE

        # Maps +rejection+ to an immutable Response for +dialect+.
        #
        # @param rejection [Legion::Extensions::Llm::Routing::Rejection]
        # @param dialect   [:native | :openai | :anthropic]
        # @return [Response]
        # @raise [ArgumentError] when +dialect+ is not one of the three accepted symbols
        def self.call(rejection:, dialect:)
          unless DIALECTS.include?(dialect)
            raise ArgumentError,
                  "[llm][routing_error_mapper] unrecognised dialect=#{dialect.inspect}; " \
                  "accepted: #{DIALECTS.map(&:inspect).join(', ')}"
          end

          kind   = rejection.kind
          reason = rejection.reason.to_s
          status  = STATUS_TABLE.fetch(kind).fetch(dialect)
          types   = TYPE_TABLE.fetch(kind)
          headers = build_headers(kind: kind)
          body    = build_body(dialect: dialect, reason: reason, types: types)

          Response.new(status: status, headers: headers, body: body)
        end

        # ── private class methods ────────────────────────────────────────────

        # Obtain the configured Retry-After integer (seconds). Retry-After is a
        # static API-surface setting (not a per-request-frozen selection input),
        # so bracket access to the registered default is correct here.
        def self.retry_after_value
          Legion::Settings[:llm][:api][:routing_too_early_retry_after]
        end
        private_class_method :retry_after_value

        def self.build_headers(kind:)
          return {}.freeze unless RETRY_AFTER_KINDS.include?(kind)

          { 'Retry-After' => retry_after_value.to_s }.freeze
        end
        private_class_method :build_headers

        def self.build_body(dialect:, reason:, types:)
          case dialect
          when :native    then build_native_body(reason: reason, types: types)
          when :openai    then build_openai_body(reason: reason, types: types)
          when :anthropic then build_anthropic_body(reason: reason, types: types)
          end
        end
        private_class_method :build_body

        # Native envelope: { error: { code:, message: } }
        def self.build_native_body(reason:, types:)
          {
            error: {
              code:    types.fetch(:native_code),
              message: reason
            }.freeze
          }.freeze
        end
        private_class_method :build_native_body

        # OpenAI envelope: { error: { message:, type:, code: } }
        def self.build_openai_body(reason:, types:)
          {
            error: {
              message: reason,
              type:    types.fetch(:openai_type),
              code:    types.fetch(:openai_code)
            }.freeze
          }.freeze
        end
        private_class_method :build_openai_body

        # Anthropic envelope: { type: 'error', error: { type:, message: } }
        def self.build_anthropic_body(reason:, types:)
          {
            type:  'error',
            error: {
              type:    types.fetch(:anthropic_type),
              message: reason
            }.freeze
          }.freeze
        end
        private_class_method :build_anthropic_body
      end
    end
  end
end
