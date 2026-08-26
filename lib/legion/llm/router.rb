# frozen_string_literal: true

# ============================================================================
# Legion::LLM::Router — the per-request routing engine (SSOT v4).
#
# This file holds the Legion::LLM::Router CLASS: the sole routing authority.
# The legacy stateless module + the router/ support folder it depended on were
# reproduced into the routing/ mixins (Legion::LLM::Routing::*) and this class,
# then removed.
#
# MODEL:
#   - ONE instance per logical request:
#       router = Legion::LLM::Router.new(request:, operation:, body_model:)
#     body_model is the RAW client body model (nil or String).
#   - Request-derived facts are computed ONCE in initialize (filters, pins,
#     required capabilities, input bound, context budget, the body-model hint
#     decision). These never change for the request's lifetime.
#   - INVENTORY IS FETCHED LIVE. Every lane decision reads the single source of
#     truth (Inventory::Registry.snapshot) at the moment it decides — there is
#     no capture-once snapshot pinned at construction, no dup, no freeze of the
#     catalog here. next_lane / next_attempt read the real inventory each call.
#   - Holds the request's attempt state: exclusions, consumed targets, attempt
#     budget, last rejection.
#   - next_lane returns exactly ONE Selection or ONE typed Rejection — never
#     nil, never a lane hash, never a chain.
#
# The mixin modules in routing/ are STATELESS behavior mixed into this class.
# All per-request state lives here and nowhere else.
# ============================================================================

require 'legion/logging/helper'
require 'legion/llm/errors'
require 'legion/llm/inference/attempt_context'

require 'legion/llm/routing/filter'
require 'legion/llm/routing/rank'
require 'legion/llm/routing/fleet'
require 'legion/llm/routing/outcome'
require 'legion/llm/routing/evaluation'

require 'legion/extensions/llm/capabilities'
require 'legion/extensions/llm/taxonomies'
require 'legion/extensions/llm/routing/records'
require 'legion/extensions/llm/inventory/registry'

module Legion
  module LLM
    # The per-request routing engine (SSOT v4). The sole routing authority:
    # selection runs against (request, operation, exclusions, the LIVE inventory,
    # one settings generation) and yields one Selection or one typed Rejection.
    class Router
      include Legion::Logging::Helper
      include Routing::Filter
      include Routing::Rank
      include Routing::Fleet
      include Routing::Outcome

      # Base capabilities required by each operation, independent of request
      # shape (reproduced from router/required_capabilities.rb — D10 selection
      # time, this class is the container).
      OPERATION_BASE = {
        chat:         [].freeze,
        stream_chat:  %i[streaming].freeze,
        embed:        %i[embedding].freeze,
        image:        %i[image].freeze,
        transcribe:   %i[audio_transcription].freeze,
        translate:    [].freeze,
        speak:        %i[audio_speech].freeze,
        moderate:     %i[moderation].freeze,
        count_tokens: [].freeze
      }.freeze

      # Tiers gated by enterprise privacy mode.
      TIER_EXTERNAL = %i[cloud frontier].freeze

      SEED_PATTERN = /\A[0-9a-f]{32}\z/
      private_constant :SEED_PATTERN

      attr_reader :request, :operation, :body_model, :body_model_hint_decision,
                  :provider_pin, :instance_pin, :model_pin, :tier_pin,
                  :required_capabilities, :requested_embedding_dimensions,
                  :input_bound, :required_output_tokens, :context_budget,
                  :routing_seed, :maximum_attempts, :affinity_strength_bps,
                  :last_rejection

      # @param request    [Legion::LLM::Inference::Request] the canonical pipeline
      #        request (carries trusted_constraints and the server-created
      #        routing_context; routing settings are read from
      #        Legion::Settings[:llm][:router], not from the request)
      # @param operation  [Symbol] the requested operation (:chat, :stream_chat, :embed, ...)
      # @param body_model  [String, nil] the RAW client-body model value
      def initialize(request:, operation:, body_model:, **)
        @request   = request
        @operation = validate_operation!(operation)
        @body_model = body_model

        # Attempt state (absorbed from inference/routing_session.rb — D9).
        @exclusions       = []
        @consumed_targets = {}
        @attempts_used    = 0
        @last_rejection   = nil

        # Request-derived facts — computed ONCE, immutable for this request.
        # Settings come straight from Legion::Settings[:llm][:router] (defaults in
        # settings/router.rb); there is no captured settings-snapshot object.
        trusted = @request.trusted_constraints

        @body_model_hint_decision = body_model_hint_decision_for(
          body_model: @body_model, trusted_model: trusted&.model
        )
        @provider_pin = trusted&.provider&.to_sym
        @instance_pin = trusted&.instance_id
        @tier_pin     = validate_tier!(trusted&.tier)
        @model_pin    = resolve_model_pin(trusted)

        @required_capabilities          = required_capabilities_for(operation: @operation)
        @requested_embedding_dimensions = requested_embedding_dimensions_for
        @input_bound                    = input_bound_for
        @required_output_tokens         = required_output_tokens_for
        @context_budget                 = context_budget_for

        @routing_seed          = validate_seed!(@request.routing_context.routing_seed)
        @maximum_attempts      = positive_int!(trusted&.maximum_attempts || Legion::Settings[:llm][:router][:max_attempts],
                                               :maximum_attempts)
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
        [@maximum_attempts - @attempts_used, 0].max
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
        return attempts_exhausted(snapshot) if @attempts_used >= @maximum_attempts

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
          reason: "maximum attempts (#{@maximum_attempts}) reached",
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
        model_pin      = @model_pin
        evaluation_set = evaluate_snapshot(snapshot: snapshot, model_pin: model_pin)
        ranked         = rank_ready(evaluation_set)

        if ranked.nil? && hint_model_pin_active?
          log.info("[llm][router] action=model_hint_miss model=#{@model_pin} falling_back=weighted_selection")
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
        @body_model_hint_decision.disposition == :honored &&
          @body_model_hint_decision.model_constraint == @model_pin
      end

      # Rank the ready lanes of an evaluation set. The class does the filtering;
      # Rank takes READY lanes only (D6).
      def rank_ready(evaluation_set, **)
        rank(
          lanes:                       evaluation_set.ready_candidates.map(&:lane),
          routing_seed:                @routing_seed,
          routing_affinities:          [],
          affinity_strength_bps:       @affinity_strength_bps,
          context_budget:              @context_budget,
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
          operation_state:      filter_operation(lane: lane, operation: @operation),
          pin_state:            filter_pins(lane: lane, provider_pin: @provider_pin, instance_pin: @instance_pin,
                                            model_pin: model_pin, tier_constraint: @tier_pin),
          policy_state:         filter_policy(lane: lane, whitelist: policy[:whitelist], blacklist: policy[:blacklist]),
          capability_state:     evaluate_capabilities(lane: lane, required_capabilities: @required_capabilities),
          context_state:        evaluate_context(lane: lane, budget: @context_budget),
          dimension_state:      evaluate_dimensions(lane: lane, requested_dimensions: @requested_embedding_dimensions),
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
          operation:            @operation,
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

        # Step 0 — malformed/missing routing context.
        unless @routing_seed.is_a?(String) && @routing_seed.match?(SEED_PATTERN)
          log.warn('[llm][router] action=diagnose result=invalid_routing_context')
          return rejection_of(:invalid_routing_context, 500, 'routing context absent or malformed', gen, counts, pins)
        end

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
          provider: @provider_pin,
          instance: @instance_pin,
          model:    model_pin,
          tier:     @tier_pin
        }.compact.freeze
      end

      # ------------------------------------------------------------------
      # Selection-time request derivations (D10; reproduced from
      # router/required_capabilities.rb + router/input_bound.rb — this class is
      # the container). Computed once per instance, reused across attempts.
      # ------------------------------------------------------------------

      # The complete frozen capability requirement set for this request.
      def required_capabilities_for(operation:, **)
        caps = OPERATION_BASE.fetch(operation, []).dup
        caps << :tools             if tools_required?
        caps << :thinking          if thinking_required?
        caps << :vision            if vision_required?
        caps << :structured_output if structured_output_required?

        result = Legion::Extensions::Llm::Capabilities.normalize(caps)
        log.debug("[llm][router] action=required_capabilities operation=#{operation} caps=#{result.inspect}")
        result
      end

      def tools_required?(**)
        return true if nonempty_array?(@request.tools)
        return true if tool_choice_requires_tool?(@request.tool_choice)

        messages_contain_block_type?(@request.messages, %i[tool_use tool_result])
      end

      def tool_choice_requires_tool?(tool_choice, **)
        return false unless tool_choice.is_a?(Hash)

        mode = tool_choice[:mode]
        return false if mode.nil?

        mode_s = mode.to_s
        mode_s != 'auto' && mode_s != 'none'
      end

      def thinking_required?(**)
        return true if thinking_config_enabled?(@request.thinking)

        messages_contain_block_type?(@request.messages, %i[thinking])
      end

      def thinking_config_enabled?(thinking, **)
        return false unless thinking.is_a?(Hash)
        return false if thinking.empty?
        return false if thinking[:enabled] == false

        true
      end

      def vision_required?(**)
        messages_contain_block_type?(@request.messages, %i[image image_url])
      end

      def structured_output_required?(**)
        rf = @request.response_format
        return false unless rf.is_a?(Hash)

        type_s = rf[:type].to_s
        return true if %w[json_object json_schema].include?(type_s)

        rf[:schema].is_a?(Hash) && !rf[:schema].empty?
      end

      def messages_contain_block_type?(messages, types, **)
        return false unless messages.is_a?(Array)

        messages.any? do |message|
          content = message.content
          next false unless content.is_a?(Array)

          content.any? do |block|
            block_type = block.type
            next false if block_type.nil?

            types.include?(block_type) || types.include?(block_type.to_sym)
          end
        end
      end

      def nonempty_array?(value, **)
        value.is_a?(Array) && !value.empty?
      end

      # Conservative provider-neutral input token upper bound (byte-bound: no
      # tokenizer, no Float). Adds the configured framing overhead.
      def input_bound_for(**)
        total = text_bytes(@request.system)
        Array(@request.messages).each { |msg| total += message_text_bytes(msg) }
        total += serialized_bytes(@request.tools)           unless nil_or_empty?(@request.tools)
        total += serialized_bytes(@request.tool_choice)     unless nil_or_empty?(@request.tool_choice)
        total += serialized_bytes(@request.thinking)         unless nil_or_empty?(@request.thinking)
        total += serialized_bytes(@request.response_format)  unless nil_or_empty?(@request.response_format)
        # operation_payload successor: the old InputBound.call summed the
        # operation-specific payload; in the canonical request that rides on
        # `extra`. Over-counting only makes this admission bound MORE
        # conservative, never less — the safe direction. (Verify the source.)
        total += serialized_bytes(@request.extra)            unless nil_or_empty?(@request.extra)

        overhead = Integer(Legion::Settings[:llm][:router][:input_framing_overhead_tokens].to_i)
        raise ArgumentError, "framing overhead must be nonnegative, got #{overhead}" if overhead.negative?

        total += overhead
        log.debug("[llm][router] action=input_bound total_bytes=#{total}")
        total
      end

      def text_bytes(str, **)
        return 0 if str.nil?

        s = str.to_s
        return 0 if s.empty?

        s.encode('UTF-8', invalid: :replace, undef: :replace).bytesize
      end

      def message_text_bytes(msg, **)
        return 0 if msg.nil?

        content = msg.content
        return 0 if content.nil?

        case content
        when String then text_bytes(content)
        when Array  then content.sum { |block| content_block_bytes(block) }
        else 0
        end
      end

      def content_block_bytes(block, **)
        return 0 if block.nil?

        case block.type&.to_s
        when 'text', 'thinking'
          text_bytes(block.text)
        when 'tool_use'
          input = block.input
          text_bytes(block.name) + (nil_or_empty?(input) ? 0 : serialized_bytes(input))
        when 'tool_result'
          result_content = block.text
          case result_content
          when String then text_bytes(result_content)
          when Array  then result_content.sum { |b| text_bytes(b.respond_to?(:text) ? b.text : nil) }
          else 0
          end
        else 0
        end
      end

      def serialized_bytes(value, **)
        Legion::JSON.dump(value).bytesize
      end

      def nil_or_empty?(value, **)
        case value
        when nil              then true
        when String           then value.strip.empty?
        when Array, Hash then value.empty?
        else false
        end
      end

      # Required output tokens for the context budget. The request carries the
      # max output token allowance under tokens[:max].
      def required_output_tokens_for(**)
        tokens = @request.tokens
        raw = tokens.is_a?(Hash) ? tokens[:max] : nil
        raw.nil? ? 0 : nonneg_int!(raw, :required_output_tokens)
      end

      # The routing-time context budget the context filter compares against each
      # lane's window. For :embed this is deliberately ZERO: an embedding request
      # carries no framed body — the input text is passed separately to
      # Call::Embeddings and re-chunked POST-selection against the SELECTED lane's
      # own authoritative context contract (Call::Embeddings#chunk_char_budget) —
      # so pre-proving a context window at routing time is wrong. The empty body
      # still yields @input_bound == input_framing_overhead_tokens and the default
      # tokens[:max] still yields a nonzero @required_output_tokens, so without
      # this short-circuit every embed lane whose context evidence is unknown
      # (vLLM max_model_len nil, Ollama num_ctx not yet enriched) evaluates
      # context_state :unknown and is rejected :too_early. A zero budget makes
      # evaluate_context return :not_applicable. Every other operation frames a
      # request body whose size the lane's window must admit, so its budget stays
      # the byte-bound input plus the required output allowance.
      def context_budget_for(**)
        return 0 if @operation == :embed

        @input_bound + @required_output_tokens
      end

      # The requested embedding dimensionality, for :embed only. Sourced from the
      # request's extra payload; nil (→ :not_applicable) for every other operation.
      def requested_embedding_dimensions_for(**)
        return nil unless @operation == :embed

        raw = @request.extra.is_a?(Hash) ? @request.extra[:embedding_dimensions] : nil
        return nil if raw.nil?

        int = Integer(raw)
        int.positive? ? int : nil
      end

      # ------------------------------------------------------------------
      # ctor validation (reproduced from router/request_requirements.rb — D1).
      # ------------------------------------------------------------------

      def resolve_model_pin(trusted, **)
        trusted_model = trusted&.model
        return trusted_model unless trusted_model.nil?
        return @body_model_hint_decision.model_constraint if @body_model_hint_decision.disposition == :honored

        nil
      end

      def validate_operation!(operation, **)
        op = operation.to_sym
        raise ArgumentError, "invalid operation #{operation.inspect}" unless Legion::Extensions::Llm::Taxonomies::OPERATIONS.include?(op)

        op
      end

      def validate_tier!(tier, **)
        return nil if tier.nil?

        sym = tier.to_sym
        raise ArgumentError, "invalid tier #{tier.inspect}" unless Legion::Extensions::Llm::Taxonomies::TIERS.include?(sym)

        sym
      end

      def validate_seed!(seed, **)
        raise Legion::LLM::Errors::InvalidRoutingContext, 'router built without a trusted routing seed' unless seed.is_a?(String) && seed.match?(SEED_PATTERN)

        seed
      end

      def nonneg_int!(value, field, **)
        int = Integer(value)
        raise ArgumentError, "#{field} must be >= 0" if int.negative?

        int
      end

      def positive_int!(value, field, **)
        int = Integer(value)
        raise ArgumentError, "#{field} must be positive" unless int.positive?

        int
      end
    end
  end
end
