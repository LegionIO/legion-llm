# frozen_string_literal: true

# ============================================================================
# Legion::LLM::Router — the per-request routing engine (SSOT v4).
#
# This file holds the Legion::LLM::Router CLASS: the sole routing authority.
# The legacy stateless module + the router/ support folder it depended on were
# reproduced into the routing/ mixins (Legion::LLM::Routing::*) and this class,
# then removed.
#
# One Router owns attempt state for one immutable RequestRequirements value.
# Requirements are constructed before routing; this class never derives request
# semantics. Each decision reads one live immutable Inventory snapshot and
# returns one authoritative Selection or typed Rejection.
# ============================================================================

require 'legion/logging/helper'
require 'legion/llm/errors'
require 'legion/llm/inference/attempt_context'

require 'legion/llm/routing/filter'
require 'legion/llm/routing/rank'
require 'legion/llm/routing/fleet'
require 'legion/llm/routing/outcome'
require 'legion/llm/routing/evaluation'
require 'legion/llm/routing/requirements'

require 'legion/extensions/llm/capabilities'
require 'legion/extensions/llm/taxonomies'
require 'legion/extensions/llm/routing/records'
require 'legion/extensions/llm/inventory/registry'

module Legion
  module LLM
    # The per-request routing engine and sole selection authority. Immutable
    # requirements, request-local exclusions and one live Inventory snapshot
    # yield one Selection or typed Rejection per decision.
    class Router
      include Legion::Logging::Helper
      include Routing::Filter
      include Routing::Rank
      include Routing::Fleet
      include Routing::Outcome

      # Tiers gated by enterprise privacy mode.
      TIER_EXTERNAL = %i[cloud frontier].freeze

      attr_reader :requirements, :affinity_strength_bps, :last_rejection

      def initialize(requirements:)
        raise ArgumentError, 'router requires Routing::RequestRequirements' unless requirements.is_a?(Legion::Extensions::Llm::Routing::RequestRequirements)

        @requirements = requirements

        # Attempt state (absorbed from inference/routing_session.rb — D9).
        @exclusions       = []
        @consumed_targets = {}
        @attempts_used    = 0
        @last_rejection   = nil

        @affinity_strength_bps = Legion::Settings[:llm][:router][:affinity_strength_bps]
      end

      # Request-local exclusion set (frozen copy — callers never mutate it).
      def exclusions(**)
        @exclusions.dup.freeze
      end

      # Consumed provider+instance+model targets for this request.
      def consumed_targets(**)
        @consumed_targets.keys.freeze
      end

      # ------------------------------------------------------------------
      # Status queries (class-level; Q5). Stateless registry/settings reads
      # consumed by the API status endpoints — never per-request state.
      # ------------------------------------------------------------------

      # Routing is enabled when at least one instance has a complete publication
      # in the Registry.
      def self.routing_enabled?(**)
        Legion::Extensions::Llm::Inventory::Registry.snapshot
                                                    .each_publication_status.any? { |ps| ps.state == :complete }
      end

      # The tier priority order. ONE settings spelling: llm.router.tier_priority
      # (default defined in lib/legion/llm/settings/router.rb, so the read never
      # needs a || fallback).
      def self.tier_priority(**)
        Array(Legion::Settings[:llm][:router][:tier_priority]).filter_map do |tier|
          tier.to_sym if tier.respond_to?(:to_sym)
        end
      end

      # Whether a tier can be used right now.
      #   :local / :direct — always available
      #   :fleet           — available when Legion::Transport is loaded
      #   :cloud / :frontier — available unless privacy mode
      def self.tier_available?(tier, **)
        sym = tier.to_sym
        return false if TIER_EXTERNAL.include?(sym) && privacy_mode?
        return Legion.const_defined?('Transport', false) if sym == :fleet

        true
      end

      # Enterprise privacy mode (delegates to the shared settings owner;
      # Legion::Settings is a hard dependency — no respond_to? guard).
      def self.privacy_mode?(**)
        Legion::Settings.enterprise_privacy?
      end

      # ------------------------------------------------------------------
      # Attempt state (reproduced from inference/routing_session.rb — D9).
      # ------------------------------------------------------------------

      # Targets remaining before the attempt budget is spent.
      def attempts_remaining(**)
        [@requirements.maximum_attempts - @attempts_used, 0].max
      end

      # True when value is a typed Routing::Rejection (never a Selection).
      def rejection?(value, **)
        value.is_a?(Legion::Extensions::Llm::Routing::Rejection)
      end

      # ------------------------------------------------------------------
      # Selection — one Selection or one typed Rejection. Reads the LIVE
      # inventory (never a snapshot passed in): the single source of truth is
      # fetched at the moment of the decision.
      # ------------------------------------------------------------------
      def next_lane(**)
        selection_for(current_inventory)
      end

      # next_lane with the exhaustion guard + attempt-context construction: the
      # executor's hot path. Returns an AttemptContext, or a typed Rejection when
      # the attempt budget is spent or the selection went stale against the live
      # inventory.
      def next_attempt(**)
        snapshot = current_inventory
        return attempts_exhausted(snapshot) if @attempts_used >= @requirements.maximum_attempts

        selection = selection_for(snapshot)
        return selection if rejection?(selection)

        consume!(selection)

        begin
          Legion::LLM::Inference::AttemptContext.build(
            selection: selection, snapshot: snapshot, attempt_number: @attempts_used
          )
        rescue Legion::LLM::Inference::AttemptContext::Stale => e
          # Target stays consumed; owner captures fresh inventory and retries.
          log.debug("[llm][router] action=stale_selection reason=#{e.message}")
          stale_selection(snapshot)
        end
      end

      # next_attempt that raises Errors::RoutingRejected on a Rejection (the
      # streaming-preflight path — rejection must surface BEFORE the SSE response
      # opens).
      def next_attempt!(**)
        result = next_attempt
        return result unless rejection?(result)

        raise Legion::LLM::Errors::RoutingRejected.new(rejection: result)
      end

      # Additional request-local exclusion (quota domain, policy, etc.).
      def add_exclusion(exclusion:, **)
        @exclusions << exclusion
        log.debug("[llm][router] action=exclusion_added kind=#{exclusion.target_kind} " \
                  "reason=#{exclusion.reason}")
        exclusion
      end

      # Classify one SelectionDispatch::Result via the Routing::Outcome mixin,
      # apply the returned action's exclusions and (for instance_unavailable) the
      # exact global transition, and return the Action.
      def classify(dispatch_result:, attempt_context:, **)
        action = classify_outcome(
          outcome: dispatch_result.outcome, attempt_context: attempt_context,
          attempts_remaining: attempts_remaining
        )
        apply_global_transition(action.global_transition) if action.global_transition
        action.exclusions.each { |ex| add_exclusion(exclusion: ex) }
        log.debug("[llm][router] action=outcome_classified kind=#{dispatch_result.outcome.kind} " \
                  "disposition=#{action.disposition} exclusions_added=#{action.exclusions.size}")
        action
      end

      # Record a consumed selection: consume the target BEFORE any external
      # action, atomically with the attempt-count increment. A consumed tuple
      # cannot be reselected this logical request regardless of lane/generation
      # change.
      def consume!(selection, **)
        key = selection.attempt_target_key
        @attempts_used += 1
        @consumed_targets[key] = true
        @exclusions << Legion::Extensions::Llm::Routing::Exclusion.new(
          target_kind: :attempt_target, target: key, reason: 'attempt_consumed',
          evidence: { attempt_number: @attempts_used }, lifetime: :request
        )
        log.debug("[llm][router] action=attempt_consumed attempt_number=#{@attempts_used} target=#{key}")
      end

      # Apply a GlobalTransition (instance_unavailable) from a classification.
      def apply_global_transition(transition, **)
        Legion::Extensions::Llm::Inventory::Registry.dispatch_instance_unavailable(
          instance_key:       transition.instance_key,
          publisher_token_id: transition.publisher_token_id,
          reason:             transition.reason
        )
      end

      # The attempts_exhausted Rejection for the current budget state.
      def attempts_exhausted(snapshot, **)
        Legion::Extensions::Llm::Routing::Rejection.new(
          kind: :attempts_exhausted,
          reason: "maximum attempts (#{@requirements.maximum_attempts}) reached",
          inventory_generation: snapshot.generation, candidate_counts: {}, http_status: 503
        )
      end

      # The stale_selection Rejection (a Selection no longer valid against fresh
      # inventory).
      def stale_selection(snapshot, **)
        Legion::Extensions::Llm::Routing::Rejection.new(
          kind: :stale_selection, reason: 'selected lane drifted from snapshot generation',
          inventory_generation: snapshot.generation, candidate_counts: {}
        )
      end

      private

      # The single source of truth for inventory — read live, every decision.
      def current_inventory(**)
        Legion::Extensions::Llm::Inventory::Registry.snapshot
      end

      # Run selection against one inventory read. On a hint-miss (an HONORED
      # body-model hint that matched no candidate) re-evaluate WITHOUT the pin
      # (N x N: route to ANY qualifying lane). A trusted X-Legion-Model pin never
      # falls back — explicit pins stay hard, and their miss stands as a real
      # no-lane rejection.
      def selection_for(snapshot, **)
        model_pin      = @requirements.model_pin
        evaluation_set = evaluate_snapshot(snapshot: snapshot, model_pin: model_pin)
        ranked         = rank_ready(evaluation_set)

        if ranked.nil? && hint_model_pin_active?
          log.info("[llm][router] action=model_hint_miss model=#{@requirements.model_pin} falling_back=weighted_selection")
          model_pin      = nil
          evaluation_set = evaluate_snapshot(snapshot: snapshot, model_pin: model_pin)
          ranked         = rank_ready(evaluation_set)
        end

        return build_selection(ranked: ranked, snapshot: snapshot) unless ranked.nil?

        @last_rejection = reject_no_candidates(evaluation_set: evaluation_set, model_pin: model_pin)
      end

      # True only when the model pin is HINT-derived (an honored body-model
      # decision whose constraint is the active pin). A trusted X-Legion-Model
      # pin supersedes the hint and never qualifies — explicit pins stay hard and
      # their miss is a caller error, not a fallback.
      def hint_model_pin_active?(**)
        @requirements.body_model_hint_decision.disposition == :honored &&
          @requirements.body_model_hint_decision.model_constraint == @requirements.model_pin
      end

      # Rank the ready lanes of an evaluation set. The class does the filtering;
      # Rank takes READY lanes only (D6).
      def rank_ready(evaluation_set, **)
        rank(
          lanes:                       evaluation_set.ready_candidates.map(&:lane),
          routing_seed:                @requirements.routing_seed,
          routing_affinities:          [],
          affinity_strength_bps:       @affinity_strength_bps,
          context_budget:              @requirements.context_budget,
          preferred_context_range_for: ->(lane) { preferred_context_range_for(lane: lane) }
        )
      end

      # Iterate every lane in the inventory read, evaluate all axes via the
      # Filter mixin, and return an immutable EvaluationSet (the orchestration
      # from router/candidate_evaluator.rb — D8: the split's orchestration lives
      # in the class, the axes live in the Filter mixin).
      def evaluate_snapshot(snapshot:, model_pin:, **)
        candidates = []
        snapshot.each_lane { |lane| candidates << evaluate_lane(lane: lane, snapshot: snapshot, model_pin: model_pin) }

        publication_statuses = []
        snapshot.each_publication_status { |ps| publication_statuses << ps }

        log.debug("[llm][router] action=evaluated candidates=#{candidates.size} " \
                  "pub_statuses=#{publication_statuses.size} generation=#{snapshot.generation}")

        Legion::LLM::Routing::EvaluationSet.new(
          candidates: candidates, publication_statuses: publication_statuses,
          inventory_generation: snapshot.generation
        )
      end

      # Build one CandidateEvaluation for a single lane across every axis.
      def evaluate_lane(lane:, snapshot:, model_pin:, **)
        instance     = snapshot.instance(instance_key: lane.instance_key)
        pub_status   = snapshot.publication_status(instance_key: lane.instance_key)
        policy       = model_policy_for(lane: lane)
        weight_state = filter_weight(lane: lane)

        Legion::LLM::Routing::CandidateEvaluation.new(
          lane:                 lane,
          instance:             instance,
          publication_status:   pub_status,
          operation_state:      filter_operation(lane: lane, operation: @requirements.operation),
          pin_state:            filter_pins(lane: lane, provider_pin: @requirements.provider_pin, instance_pin: @requirements.instance_pin,
                                            model_pin: model_pin, tier_constraint: @requirements.tier_pin),
          policy_state:         filter_policy(lane: lane, whitelist: policy[:whitelist], blacklist: policy[:blacklist]),
          capability_state:     evaluate_capabilities(lane: lane, required_capabilities: @requirements.required_capabilities),
          context_state:        evaluate_context(lane: lane, budget: @requirements.context_budget),
          dimension_state:      evaluate_dimensions(lane: lane, requested_dimensions: @requirements.requested_embedding_dimensions),
          availability_state:   filter_availability(instance: instance),
          exclusion_state:      filter_exclusions(lane: lane, exclusions: exclusions),
          fleet_contract_state: filter_fleet(lane: lane),
          weight_state:         weight_state,
          weight_inputs:        weight_state == :enabled ? lane.weight_inputs : nil
        )
      end

      # Construct the Selection from the RankedLane winner (the D6 seam:
      # ranked.lane, not ranked.evaluation.lane). Freezes the REQUESTED fine
      # operation, matched against the lane's coarse type by the evaluator.
      def build_selection(ranked:, snapshot:, **)
        lane     = ranked.lane
        instance = snapshot.instance(instance_key: lane.instance_key)

        Legion::Extensions::Llm::Routing::Selection.new(
          inventory_generation: snapshot.generation,
          lane_id:              lane.lane_id,
          instance_key:         lane.instance_key,
          provider_family:      lane.provider_family,
          instance_id:          lane.instance_id,
          model:                lane.model,
          operation:            @requirements.operation,
          callable_handle:      lane.callable_handle,
          publisher_token_id:   instance.publisher_token_id,
          capability_evidence:  lane.capability_evidence,
          context_evidence:     lane.context_evidence,
          weight_inputs:        ranked.weight_inputs,
          base_weight:          ranked.base_weight,
          preference_ppm:       ranked.preference_ppm,
          effective_weight:     ranked.effective_weight,
          rendezvous_score:     ranked.rendezvous_score
        )
      end

      # ------------------------------------------------------------------
      # No-candidate rejection reduction (reproduced from
      # router/rejection_diagnostics.rb — D10 selection-time, this class is the
      # container). NEVER infers :attempts_exhausted or :stale_selection.
      # ------------------------------------------------------------------
      def reject_no_candidates(evaluation_set:, model_pin:, **)
        candidates   = evaluation_set.candidates
        pub_statuses = evaluation_set.publication_statuses
        gen          = evaluation_set.inventory_generation
        counts       = rejection_counts(candidates, pub_statuses)
        pins         = rejection_pins(model_pin)

        # This method runs ONLY on the no-ready-candidate path, so one line
        # here gives every typed rejection its per-axis diagnostic (which lanes
        # are context_rejected vs capability_unknown vs availability_unknown).
        log.warn("[llm][router] action=no_candidate candidates=#{candidates.size} " \
                 "pub_statuses=#{pub_statuses.size} generation=#{gen} counts=#{counts.inspect}")

        # Steps 1-2 — explicit-pin checks (skipped when no pins supplied).
        if pins.any?
          if candidates.any? && candidates.all? { |c| c.pin_state == :mismatch } &&
             (pub_statuses.empty? || pub_statuses.all? { |s| s.state == :complete })
            return rejection_of(:invalid_request, 400,
                                'explicit pin not found in any complete publication scope', gen, counts, pins)
          end

          unless pub_statuses.any? { |s| s.state == :complete }
            return rejection_of(:too_early, 425,
                                'explicit pin resolution blocked; all publication scopes are initializing or absent',
                                gen, counts, pins)
          end
        end

        # Cold/empty catalog.
        if candidates.empty?
          return rejection_of(:too_early, 425,
                              'no selectable candidates; catalog is cold or all scopes are initializing',
                              gen, counts, pins)
        end

        # Step 3 — policy_denied 403.
        if candidates.all? { |c| c.policy_state == :denied || c.weight_state == :disabled }
          return rejection_of(:policy_denied, 403, 'all candidates are policy denied or weight disabled',
                              gen, counts, pins)
        end

        policy_eligible = candidates.reject { |c| c.policy_state == :denied || c.weight_state == :disabled }

        # Step 4 — failed_dependency 424. Fires when EVERY policy-eligible lane
        # conclusively lacks the request (operation :unsupported OR capability
        # :unsupported) under complete scopes. An incidental :unknown on the OTHER
        # axis of an already-conclusively-unsupported lane does not soften this: a
        # lane that cannot perform the operation is a settled dependency failure
        # regardless of its capability evidence. A lane that is merely :unknown
        # (not conclusively unsupported) is not counted by the all?, so it falls
        # through to the transient too_early diagnosis (step 7).
        all_scopes_complete    = pub_statuses.empty? || pub_statuses.all? { |s| s.state == :complete }
        all_op_cap_unsupported = policy_eligible.all? { |c| c.operation_state == :unsupported || c.capability_state == :unsupported }

        if all_scopes_complete && all_op_cap_unsupported
          return rejection_of(:failed_dependency, 424,
                              'all eligible candidates conclusively lack required operation or capability',
                              gen, counts, pins)
        end

        # Step 4b — failed_dependency 424 within the PINNED scope (extracted to
        # keep this ladder under the complexity budget).
        pin_dependency = pin_scope_dependency_rejection(
          policy_eligible: policy_eligible, all_scopes_complete: all_scopes_complete,
          gen: gen, counts: counts, pins: pins
        )
        return pin_dependency if pin_dependency

        has_tripped   = policy_eligible.any? { |c| c.availability_state == :unavailable }
        fit_available = policy_eligible.any? do |c|
          conclusively_fit?(c) && c.availability_state == :available && c.pin_state == :match
        end

        # Step 5 — service_unavailable 503 (tripped before unknown).
        if has_tripped && !fit_available
          return rejection_of(:service_unavailable, 503,
                              'tripped instance reported before unknown evidence; recovers without a restart',
                              gen, counts, pins)
        end

        # Step 6 — invalid_request 400 (terminal settled-unknown capability). Only
        # when EVERY lane INSIDE the selectable scope (pin_state :match and
        # operation_state :supported) reports capability_state :unknown, under a
        # complete scope with no fit+available match: no lane that could actually
        # be chosen can attest the capability, and none ever will without an
        # operator enable_* override, so it is terminal. Pin-mismatched or
        # operation-:unsupported lanes are outside the selectable scope and never
        # soften this — that keeps a provider-pinned settled-unknown a typed 400
        # even when a capable lane exists under a DIFFERENT provider. A selectable
        # lane carrying a DIFFERENT capability state (e.g. a conclusive
        # :unsupported) instead means the evidence is not homogeneously unknown
        # → too_early (step 7).
        in_pin_scope = policy_eligible.select { |c| c.pin_state == :match && c.operation_state == :supported }
        if all_scopes_complete && !fit_available && in_pin_scope.any? &&
           in_pin_scope.all? { |c| c.capability_state == :unknown }
          return rejection_of(:invalid_request, 400,
                              'no lane can attest the required capabilities; published evidence is unknown and no operator enable_* override is set',
                              gen, counts, pins)
        end

        # Step 7 — too_early 425 (unknown evidence on a hard-filter axis).
        has_any_unknown = policy_eligible.any? do |c|
          c.operation_state == :unknown || c.capability_state == :unknown || c.context_state == :unknown ||
            c.dimension_state == :unknown || c.availability_state == :unknown || c.fleet_contract_state == :unknown
        end
        if has_any_unknown
          return rejection_of(:too_early, 425,
                              'some candidates have unknown evidence; system may still be initializing',
                              gen, counts, pins)
        end

        # Step 8 — context_rejected 400.
        if policy_eligible.any? { |c| c.context_state == :rejected || c.dimension_state == :rejected }
          return rejection_of(:context_rejected, 400, 'all candidates fail context or dimension constraints',
                              gen, counts, pins)
        end

        # Step 9 — service_unavailable 503 (all eligible consumed or unavailable).
        rejection_of(:service_unavailable, 503,
                     'all eligible candidates are consumed or unavailable for this request',
                     gen, counts, pins)
      end

      # Step 4b — failed_dependency 424 within the PINNED scope. When explicit
      # pins are present and EVERY pin-MATCHED eligible lane conclusively lacks the
      # requested operation or capability, the pinned target cannot serve this
      # request and explicit pins never fall back to another provider. A capable
      # pin-MISMATCHED sibling must NOT downgrade this to the retryable 503 at
      # step 9 (that reintroduces the 529 fail-forward regression bar 6 guards
      # against). Pin-matched lanes that are merely :unknown (not conclusively
      # unsupported) are not counted, so they still fall through to the
      # settled-unknown 400 (step 6) or the transient too_early (step 7). Returns
      # the Rejection or nil (no pinned-scope dependency failure).
      def pin_scope_dependency_rejection(policy_eligible:, all_scopes_complete:, gen:, counts:, pins:, **)
        return nil unless pins.any? && all_scopes_complete

        pin_matched = policy_eligible.select { |c| c.pin_state == :match }
        return nil unless pin_matched.any? &&
                          pin_matched.all? { |c| c.operation_state == :unsupported || c.capability_state == :unsupported }

        rejection_of(:failed_dependency, 424,
                     'pinned target conclusively lacks the required operation or capability',
                     gen, counts, pins)
      end

      # "Conclusively fit" = authoritative pass on every evidence axis. Only
      # availability, exclusion, or pin state can still block dispatch.
      def conclusively_fit?(candidate, **)
        candidate.operation_state == :supported &&
          candidate.capability_state == :supported &&
          %i[fits not_applicable].include?(candidate.context_state) &&
          %i[match not_applicable].include?(candidate.dimension_state)
      end

      def rejection_of(kind, http_status, reason, gen, counts, pins, **)
        Legion::Extensions::Llm::Routing::Rejection.new(
          kind: kind, reason: reason, inventory_generation: gen,
          candidate_counts: counts, explicit_pins: pins, http_status: http_status
        )
      end

      # Frozen Symbol-keyed count of each axis state and publication scope state.
      # Diagnostic only; never drives a second selection.
      def rejection_counts(candidates, pub_statuses, **)
        counts = Hash.new(0)
        candidates.each do |c|
          counts[:"operation_#{c.operation_state}"]           += 1
          counts[:"pin_#{c.pin_state}"]                       += 1
          counts[:"policy_#{c.policy_state}"]                 += 1
          counts[:"capability_#{c.capability_state}"]         += 1
          counts[:"context_#{c.context_state}"]               += 1
          counts[:"dimension_#{c.dimension_state}"]           += 1
          counts[:"availability_#{c.availability_state}"]     += 1
          counts[:"exclusion_#{c.exclusion_state}"]           += 1
          counts[:"fleet_contract_#{c.fleet_contract_state}"] += 1
          counts[:"weight_#{c.weight_state}"]                 += 1
        end
        pub_statuses.each { |s| counts[:"publication_#{s.state}"] += 1 }
        counts.freeze
      end

      # Sanitized hash of the non-nil routing pins for this request (the model
      # pin reflects the pin actually in force for the evaluation — nil after a
      # hint-miss fallback, so a genuine no-lane is not reported as a pin miss).
      def rejection_pins(model_pin, **)
        {
          provider: @requirements.provider_pin,
          instance: @requirements.instance_pin,
          model:    model_pin,
          tier:     @requirements.tier_pin
        }.compact.freeze
      end
    end
  end
end
