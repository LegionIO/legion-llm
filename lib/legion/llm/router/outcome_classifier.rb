# frozen_string_literal: true

module Legion
  module LLM
    module Router
      # Provider-neutral outcome classification (SSOT v3 §16). Consumes ONLY a
      # Phase 1 normalized ProviderOutcome plus the exact AttemptContext; it never
      # sees a provider name, HTTP status, or response body for branching.
      module OutcomeClassifier
        extend Legion::Logging::Helper

        # Immutable global-availability transition. The only accepted kind is
        # :instance_unavailable; identity/token/reason come from the AttemptContext
        # and normalized outcome.
        class GlobalTransition
          attr_reader :kind, :instance_key, :publisher_token_id, :reason

          def initialize(instance_key:, publisher_token_id:, reason:, kind: :instance_unavailable)
            raise ArgumentError, "unsupported global transition kind: #{kind.inspect}" unless kind == :instance_unavailable

            @kind = kind
            @instance_key = instance_key
            @publisher_token_id = publisher_token_id
            @reason = reason
            freeze
          end
        end

        # Immutable classified action. `outcome` preserves the originating
        # ProviderOutcome for emission/diagnostics (never re-classified downstream).
        class Action
          attr_reader :disposition, :global_transition, :exclusions, :rejection, :outcome

          def self.success(outcome:)
            new(disposition: :success, outcome: outcome)
          end

          def self.retry(exclusions:, outcome:, global_transition: nil)
            new(disposition: :retry, exclusions: exclusions, global_transition: global_transition, outcome: outcome)
          end

          def self.terminal(rejection:, outcome:)
            new(disposition: :terminal, rejection: rejection, outcome: outcome)
          end

          def initialize(disposition:, outcome:, exclusions: [], global_transition: nil, rejection: nil)
            case disposition
            when :success
              raise ArgumentError, 'success carries no rejection/transition' if rejection || global_transition
            when :retry
              raise ArgumentError, 'retry carries no rejection' if rejection
            when :terminal
              raise ArgumentError, 'terminal requires a rejection' if rejection.nil?
              raise ArgumentError, 'terminal carries no global transition' if global_transition
            else
              raise ArgumentError, "unknown disposition: #{disposition.inspect}"
            end

            @disposition = disposition
            @outcome = outcome
            @exclusions = exclusions.freeze
            @global_transition = global_transition
            @rejection = rejection
            freeze
          end

          def success? = @disposition == :success
          def retry? = @disposition == :retry
          def terminal? = @disposition == :terminal
        end

        # Outcomes that retry against a different eligible target when attempts remain.
        RETRYABLE = %i[
          instance_unavailable overloaded model_not_ready timeout connection_failure
          provider_error malformed_output tool_failure rate_limited
          authentication authorization billing model_missing context_rejected
        ].freeze

        # Terminal provider outcomes → best-fit Rejection kind. cancelled/client_disconnect
        # preserve the outcome so the owner can skip HTTP rendering for a gone client.
        TERMINAL_REJECTION_KIND = {
          policy:            :policy_denied,
          invalid_request:   :invalid_request,
          safety_refusal:    :invalid_request,
          cancelled:         :invalid_request,
          client_disconnect: :invalid_request
        }.freeze

        def self.call(outcome:, attempt_context:, attempts_remaining:)
          kind = outcome.kind
          return Action.success(outcome: outcome) if kind == :success

          if kind == :instance_unavailable
            # The exact instance MUST be marked unavailable regardless of attempts;
            # attempts_exhausted (if any) is produced by RoutingSession#next_attempt's
            # counter guard on the following selection.
            return Action.retry(
              exclusions: [], outcome: outcome,
              global_transition: GlobalTransition.new(
                instance_key:       attempt_context.selection.instance_key,
                publisher_token_id: attempt_context.selection.publisher_token_id,
                reason:             outcome.reason
              )
            )
          end

          if RETRYABLE.include?(kind)
            return attempts_exhausted(outcome) unless attempts_remaining.positive?

            return Action.retry(exclusions: quota_exclusions(outcome), outcome: outcome)
          end

          rejection_kind = TERMINAL_REJECTION_KIND[kind]
          raise ArgumentError, "unclassifiable provider outcome kind: #{kind.inspect}" if rejection_kind.nil?

          Action.terminal(outcome: outcome, rejection: terminal_rejection(rejection_kind, outcome))
        end

        def self.quota_exclusions(outcome)
          domain = outcome.quota_domain
          return [] unless domain.is_a?(Legion::Extensions::Llm::Routing::QuotaDomainKey)

          # Authoritative provider-declared domain. A domain no other lane publishes
          # excludes nothing (harmless), so we never broaden past the consumed target.
          [Legion::Extensions::Llm::Routing::Exclusion.new(
            target_kind: :quota_domain, target: domain, reason: 'rate_limited',
            evidence: { retry_after: outcome.retry_after }, lifetime: :request
          )]
        end
        private_class_method :quota_exclusions

        def self.attempts_exhausted(outcome)
          Action.terminal(
            outcome:   outcome,
            rejection: Legion::Extensions::Llm::Routing::Rejection.new(
              kind: :attempts_exhausted, reason: "attempts exhausted; last outcome=#{outcome.kind}",
              inventory_generation: 0, candidate_counts: {}, http_status: 503
            )
          )
        end
        private_class_method :attempts_exhausted

        def self.terminal_rejection(kind, outcome)
          http = kind == :policy_denied ? 403 : 400
          Legion::Extensions::Llm::Routing::Rejection.new(
            kind: kind, reason: "terminal outcome=#{outcome.kind}: #{outcome.reason}",
            inventory_generation: 0, candidate_counts: {}, http_status: http
          )
        end
        private_class_method :terminal_rejection
      end
    end
  end
end
