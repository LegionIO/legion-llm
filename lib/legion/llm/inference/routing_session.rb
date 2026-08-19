# frozen_string_literal: true

require 'legion/llm/errors'
require 'legion/llm/inference/attempt_context'
require 'legion/llm/router/outcome_classifier'

module Legion
  module LLM
    module Inference
      # Per-logical-request routing state (SSOT v3 §14.2). Owns one immutable
      # routing seed (in requirements), the accumulated request-local exclusion
      # set, and the consumed provider+instance+model target set. Reused by
      # initial dispatch, retries, streaming failover, tool-continuation turns,
      # fleet retry, and embedding batch restart — never cached globally, never
      # shared by another external request. Router.next_lane is the only selector.
      class RoutingSession
        include Legion::Logging::Helper

        attr_reader :request, :requirements, :attempt_count

        def initialize(request:, requirements:)
          @request = request
          @requirements = requirements
          @exclusions = []
          @consumed_targets = {}
          @attempt_count = 0
        end

        def routing_seed
          @requirements.routing_seed
        end

        def exclusions
          @exclusions.dup.freeze
        end

        def consumed_targets
          @consumed_targets.keys.freeze
        end

        # => AttemptContext or Phase 1 Rejection.
        def next_attempt(snapshot:)
          return attempts_exhausted(snapshot) if @attempt_count >= @requirements.maximum_attempts

          selection = Legion::LLM::Router.next_lane(
            requirements: @requirements, exclusions: exclusions, snapshot: snapshot
          )
          return selection if rejection?(selection)

          consume!(selection)

          begin
            Legion::LLM::Inference::AttemptContext.build(
              selection: selection, snapshot: snapshot, attempt_number: @attempt_count
            )
          rescue Legion::LLM::Inference::AttemptContext::Stale => e
            # Target stays consumed; owner captures a fresh snapshot and retries.
            log.debug("[llm][routing_session] action=stale_selection reason=#{e.message}")
            stale_selection(snapshot)
          end
        end

        # => AttemptContext; raises RoutingRejected when next_attempt rejected.
        def next_attempt!(snapshot:)
          result = next_attempt(snapshot: snapshot)
          return result unless rejection?(result)

          raise Legion::LLM::Errors::RoutingRejected.new(rejection: result)
        end

        # Additional request-local exclusion (quota domain, policy, etc.). Cannot
        # remove or overwrite a consumed attempt-target exclusion.
        def add_exclusion(exclusion:)
          @exclusions << exclusion
          log.debug("[llm][routing_session] action=exclusion_added kind=#{exclusion.target_kind} " \
                    "reason=#{exclusion.reason} target_kind_seen=#{exclusion.target_kind}")
          exclusion
        end

        # Classify one SelectionDispatch::Result, apply the returned action's
        # exclusions and (for instance_unavailable) the exact Phase 1 global
        # transition, and return the Action.
        def classify(dispatch_result:, attempt_context:)
          action = Legion::LLM::Router::OutcomeClassifier.call(
            outcome: dispatch_result.outcome, attempt_context: attempt_context,
            attempts_remaining: attempts_remaining
          )
          apply_global_transition(action.global_transition) if action.global_transition
          action.exclusions.each { |ex| add_exclusion(exclusion: ex) }
          log.debug("[llm][routing_session] action=outcome_classified kind=#{dispatch_result.outcome.kind} " \
                    "disposition=#{action.disposition} exclusions_added=#{action.exclusions.size}")
          action
        end

        private

        def attempts_remaining
          @requirements.maximum_attempts - @attempt_count
        end

        def rejection?(value)
          value.is_a?(Legion::Extensions::Llm::Routing::Rejection)
        end

        # Consume the selected target BEFORE any external action, atomically with
        # the attempt-count increment. A consumed tuple cannot be reselected this
        # logical request regardless of lane/offering/generation/tier/weight change.
        def consume!(selection)
          key = selection.attempt_target_key
          @attempt_count += 1
          @consumed_targets[key] = true
          @exclusions << Legion::Extensions::Llm::Routing::Exclusion.new(
            target_kind: :attempt_target, target: key, reason: 'attempt_consumed',
            evidence: { attempt_number: @attempt_count }, lifetime: :request
          )
          log.debug("[llm][routing_session] action=attempt_consumed attempt_number=#{@attempt_count} target=#{key}")
        end

        def apply_global_transition(transition)
          Legion::Extensions::Llm::Inventory::Registry.dispatch_instance_unavailable(
            instance_key:       transition.instance_key,
            publisher_token_id: transition.publisher_token_id,
            reason:             transition.reason
          )
        end

        def attempts_exhausted(snapshot)
          Legion::Extensions::Llm::Routing::Rejection.new(
            kind: :attempts_exhausted,
            reason: "maximum attempts (#{@requirements.maximum_attempts}) reached",
            inventory_generation: snapshot.generation, candidate_counts: {}, http_status: 503
          )
        end

        def stale_selection(snapshot)
          Legion::Extensions::Llm::Routing::Rejection.new(
            kind: :stale_selection, reason: 'selected lane drifted from snapshot generation',
            inventory_generation: snapshot.generation, candidate_counts: {}
          )
        end
      end
    end
  end
end
