# frozen_string_literal: true

require 'legion/logging/helper'
require 'legion/extensions/llm/routing/records'

module Legion
  module LLM
    module Routing
      # Outcome classification mixin — consumes a Phase 1 normalized
      # ProviderOutcome plus the AttemptContext and classifies into
      # success/retry/terminal. Shaped like Rank (mixin + records in one file).
      #
      # Included into the Router class; all methods are INSTANCE methods.
      module Outcome
        include Legion::Logging::Helper

        # Immutable global-availability transition. The only accepted kind is
        # :instance_unavailable; identity/token/reason come from the AttemptContext
        # and normalized outcome.
        class GlobalTransition
          attr_reader :kind, :instance_key, :publisher_token_id, :reason

          def initialize(instance_key:, publisher_token_id:, reason:, kind: :instance_unavailable, **)
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

          def self.success(outcome:, **)
            new(disposition: :success, outcome: outcome)
          end

          def self.retry(exclusions:, outcome:, global_transition: nil, **)
            new(disposition: :retry, exclusions: exclusions, global_transition: global_transition, outcome: outcome)
          end

          def self.terminal(rejection:, outcome:, **)
            new(disposition: :terminal, rejection: rejection, outcome: outcome)
          end

          def initialize(disposition:, outcome:, exclusions: [], global_transition: nil, rejection: nil, **)
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

          def success?(**) = @disposition == :success
          def retry?(**) = @disposition == :retry
          def terminal?(**) = @disposition == :terminal
        end

        # Outcomes that retry against a different eligible target when attempts remain.
        RETRYABLE = %i[
          instance_unavailable overloaded model_not_ready timeout connection_failure
          provider_error malformed_output tool_failure rate_limited
          authentication authorization billing model_missing context_rejected
        ].freeze

        # Terminal provider outcomes -> best-fit Rejection kind. cancelled/client_disconnect
        # preserve the outcome so the owner can skip HTTP rendering for a gone client.
        TERMINAL_REJECTION_KIND = {
          policy:            :policy_denied,
          invalid_request:   :invalid_request,
          safety_refusal:    :invalid_request,
          cancelled:         :invalid_request,
          client_disconnect: :invalid_request
        }.freeze

        # Classify a dispatch outcome into success/retry/terminal.
        # Pure classification — returns an Action; does NOT apply exclusions
        # or transitions (the Router's stateful #classify does that).
        #
        # @param outcome [ProviderOutcome] the normalized outcome from dispatch
        # @param attempt_context [AttemptContext] the attempt's routing context (selection, etc.)
        # @param attempts_remaining [Integer] how many attempts remain after this one
        # @return [Action]
        def classify_outcome(outcome:, attempt_context:, attempts_remaining:, **)
          kind = outcome.kind
          return Action.success(outcome: outcome) if kind == :success

          if kind == :instance_unavailable
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
            return attempts_exhausted_rejection(outcome) unless attempts_remaining.positive?

            return Action.retry(exclusions: quota_exclusions(outcome), outcome: outcome)
          end

          rejection_kind = TERMINAL_REJECTION_KIND[kind]
          raise ArgumentError, "unclassifiable provider outcome kind: #{kind.inspect}" if rejection_kind.nil?

          Action.terminal(outcome: outcome, rejection: terminal_rejection(rejection_kind, outcome))
        end

        private

        # Build request-lifetime exclusions from the outcome's quota domain.
        # Returns an empty array when the domain is not a QuotaDomainKey.
        def quota_exclusions(outcome, **)
          domain = outcome.quota_domain
          return [] unless domain.is_a?(Legion::Extensions::Llm::Routing::QuotaDomainKey)

          [Legion::Extensions::Llm::Routing::Exclusion.new(
            target_kind: :quota_domain, target: domain, reason: 'rate_limited',
            evidence: { retry_after: outcome.retry_after }, lifetime: :request
          )]
        end

        # Terminal action for attempts-exhausted: 503 rejection.
        def attempts_exhausted_rejection(outcome, **)
          Action.terminal(
            outcome:   outcome,
            rejection: Legion::Extensions::Llm::Routing::Rejection.new(
              kind: :attempts_exhausted, reason: "attempts exhausted; last outcome=#{outcome.kind}",
              inventory_generation: 0, candidate_counts: {}, http_status: 503
            )
          )
        end

        # Build a terminal rejection for policy/invalid/safety/cancelled outcomes.
        def terminal_rejection(kind, outcome, **)
          http = kind == :policy_denied ? 403 : 400
          Legion::Extensions::Llm::Routing::Rejection.new(
            kind: kind, reason: "terminal outcome=#{outcome.kind}: #{outcome.reason}",
            inventory_generation: 0, candidate_counts: {}, http_status: http
          )
        end
      end
    end
  end
end
