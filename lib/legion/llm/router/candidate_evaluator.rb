# frozen_string_literal: true

require 'legion/llm/router/candidate_evaluation'

module Legion
  module LLM
    module Router
      # SSOT v3 §9.7 — hard-filter and evidence evaluator.
      #
      # Iterates every offering in the captured snapshot, resolves the exact
      # instance and lane for supported operations, evaluates all ten axes in
      # canonical order, and returns an immutable EvaluationSet. Performs no
      # winner selection and no early return.
      #
      # Offering iteration (not lane iteration) is the authoritative source:
      # lanes exist only for supported operations, so operation unknown/
      # unsupported diagnosis must start from offerings.
      #
      # Also iterates snapshot.each_publication_status to populate
      # EvaluationSet#publication_statuses, including initializing scopes that
      # have no active offering. Those status diagnostics are inputs to
      # RejectionDiagnostics but are not CandidateEvaluation objects.
      module CandidateEvaluator
        extend Legion::Logging::Helper

        INV = Legion::Extensions::Llm::Inventory
        private_constant :INV

        class << self
          def call(requirements:, exclusions:, snapshot:, settings_snapshot:)
            excl_list = Array(exclusions).freeze
            candidates = []

            snapshot.each_offering do |offering|
              candidates << evaluate_offering(
                offering:          offering,
                requirements:      requirements,
                exclusions:        excl_list,
                snapshot:          snapshot,
                settings_snapshot: settings_snapshot
              )
            end

            publication_statuses = []
            snapshot.each_publication_status { |ps| publication_statuses << ps }

            log.debug('[llm][candidate_evaluator] action=evaluated ' \
                      "candidates=#{candidates.size} " \
                      "pub_statuses=#{publication_statuses.size} " \
                      "generation=#{snapshot.generation}")

            EvaluationSet.new(
              candidates:           candidates,
              publication_statuses: publication_statuses,
              inventory_generation: snapshot.generation
            )
          end

          private

          # Build one CandidateEvaluation for a single offering, evaluating all
          # ten axes in the §9.7 prescribed order.
          def evaluate_offering(offering:, requirements:, exclusions:, snapshot:, settings_snapshot:)
            instance_key = offering.instance_key
            instance     = snapshot.instance(instance_key: instance_key)
            pub_status   = snapshot.publication_status(instance_key: instance_key)

            # Step 1 — operation + lane derivation
            operation_state, lane = resolve_operation_and_lane(
              offering:     offering,
              requirements: requirements,
              snapshot:     snapshot
            )

            # Step 2 — provider/instance/model/tier pins
            pin_state = evaluate_pins(offering: offering, requirements: requirements)

            # Step 3 — model policy via SettingsSnapshot specificity cascade
            policy_state = evaluate_policy(offering: offering, settings_snapshot: settings_snapshot)

            # Step 4 — required capabilities (tri-state reduction + enable_* override)
            capability_state = evaluate_capabilities(
              offering:          offering,
              requirements:      requirements,
              settings_snapshot: settings_snapshot
            )

            # Step 5 — context budget against authoritative limit
            context_state = evaluate_context(
              offering:          offering,
              requirements:      requirements,
              settings_snapshot: settings_snapshot
            )

            # Step 6 — embedding dimensions when requested
            dimension_state = evaluate_dimensions(offering: offering, requirements: requirements)

            # Step 7 — exact-instance availability from InstanceRecord
            availability_state = evaluate_availability(instance: instance)

            # Step 8 — typed exclusions
            exclusion_state = evaluate_exclusions(
              offering:     offering,
              lane:         lane,
              exclusions:   exclusions,
              requirements: requirements
            )

            # Step 9 — fleet contract marker when tier is :fleet
            fleet_contract_state = evaluate_fleet_contract(offering: offering)

            # Step 10 — configured weight components
            weight_state, weight_inputs = evaluate_weight(
              lane:              lane,
              settings_snapshot: settings_snapshot
            )

            # Soft sieve input for Ranker §10.1
            preferred_context_match = evaluate_preferred_context(
              lane:              lane,
              requirements:      requirements,
              settings_snapshot: settings_snapshot
            )

            CandidateEvaluation.new(
              offering:                offering,
              instance:                instance,
              lane:                    lane,
              publication_status:      pub_status,
              operation_state:         operation_state,
              pin_state:               pin_state,
              policy_state:            policy_state,
              capability_state:        capability_state,
              context_state:           context_state,
              dimension_state:         dimension_state,
              availability_state:      availability_state,
              exclusion_state:         exclusion_state,
              fleet_contract_state:    fleet_contract_state,
              weight_state:            weight_state,
              weight_inputs:           weight_inputs,
              preferred_context_match: preferred_context_match
            )
          end

          # §9.7 step 1 — resolve operation status and derive the canonical lane.
          # Returns [operation_state, lane_or_nil].
          # Only :supported resolves a lane. A missing derived lane is :unknown
          # (incomplete authority), never authoritatively :unsupported.
          def resolve_operation_and_lane(offering:, requirements:, snapshot:)
            op_status = offering.operation_status(operation: requirements.operation)
            return [op_status, nil] unless op_status == :supported

            derived_id = INV::Identity.lane_id(
              instance_key: offering.instance_key,
              operation:    requirements.operation,
              model:        offering.model,
              offering_id:  offering.offering_id
            )
            lane = snapshot.lane(lane_id: derived_id)

            if lane.nil?
              log.debug('[llm][candidate_evaluator] action=missing_lane ' \
                        "instance=#{offering.instance_key.instance_id} " \
                        "model=#{offering.model} " \
                        "operation=#{requirements.operation}")
              return [:unknown, nil]
            end

            [:supported, lane]
          end

          # §9.7 step 2 — provider/instance/model/tier pins.
          # :match when all configured pins equal the offering's fields.
          # :mismatch when any configured pin differs.
          def evaluate_pins(offering:, requirements:)
            ik = offering.instance_key

            return :mismatch if requirements.provider_pin   && requirements.provider_pin   != ik.provider_family
            return :mismatch if requirements.instance_pin   && requirements.instance_pin   != ik.instance_id
            return :mismatch if requirements.model_pin      && requirements.model_pin      != offering.model
            return :mismatch if requirements.tier_constraint && requirements.tier_constraint != offering.tier

            :match
          end

          # §9.7 step 3 — model policy. §9.5 specificity cascade is owned by
          # SettingsSnapshot#model_policy_for. Matching is case-insensitive
          # literal substring. Blacklist always wins, even when whitelist also
          # matches.
          def evaluate_policy(offering:, settings_snapshot:)
            policy    = settings_snapshot.model_policy_for(offering: offering)
            whitelist = policy[:whitelist]
            blacklist = policy[:blacklist]
            model_lc  = offering.model.downcase

            return :denied if blacklist.any? { |e| model_lc.include?(e.downcase) }
            return :denied if whitelist.any? && whitelist.none? { |e| model_lc.include?(e.downcase) }

            :allowed
          end

          # §9.7 step 4 — capability reduction with the operator's enable_*
          # routing override (fail-forward decision 2).
          # All satisfied → :supported; any unknown → :unknown (highest
          # priority); any not-ready with no unknown → :unsupported.
          def evaluate_capabilities(offering:, requirements:, settings_snapshot:)
            caps = requirements.required_capabilities
            return :supported if caps.empty?

            any_unknown     = false
            any_unsupported = false

            caps.each do |cap|
              case resolved_capability_status(
                offering:          offering,
                capability:        cap,
                settings_snapshot: settings_snapshot
              )
              when :unknown     then any_unknown     = true
              when :unsupported then any_unsupported = true
              end
            end

            return :unknown     if any_unknown
            return :unsupported if any_unsupported

            :supported
          end

          # Axis state for one required capability. The operator's cascaded
          # enable_<cap> for the exact instance (config name) is consulted
          # ONLY when the published evidence is :unknown — the provider does
          # not publish this (contract-forbidden as evidence), the router
          # reads the config: operator true satisfies the axis, operator
          # false makes it not ready, unset falls back to the evidence.
          # Authoritative :supported/:unsupported evidence is never overridden.
          def resolved_capability_status(offering:, capability:, settings_snapshot:)
            status = offering.capability_status(capability: capability)
            return status unless status == :unknown

            override = settings_snapshot.capability_override_for(
              provider_family: offering.instance_key.provider_family,
              instance_id:     offering.instance_key.instance_id,
              model:           offering.model,
              capability:      capability
            )
            return :supported   if override == true
            return :unsupported if override == false

            status
          end

          # §9.7 step 5 — context budget.
          # Zero budget → :not_applicable (no context requirement).
          # Authoritative limit: fits when budget <= (limit * headroom_ppm) / 1_000_000.
          # Absent or unknown context evidence → :unknown.
          def evaluate_context(offering:, requirements:, settings_snapshot:)
            budget = requirements.required_context_budget
            return :not_applicable if budget.zero?

            ctx_ev = offering.context_evidence
            return :unknown unless ctx_ev.known?

            limit    = ctx_ev.value
            headroom = settings_snapshot.context_headroom_ppm
            budget <= (limit * headroom) / 1_000_000 ? :fits : :rejected
          end

          # §9.7 step 6 — embedding dimensions.
          # Nil requested → :not_applicable.
          # Authoritative evidence is a sorted Array of positive Integers.
          # :match when the requested dimension appears in the supported set;
          # :rejected when the set is known but excludes the requested value.
          # Unknown evidence → :unknown.
          def evaluate_dimensions(offering:, requirements:)
            requested = requirements.requested_embedding_dimensions
            return :not_applicable if requested.nil?

            dim_ev = offering.embedding_dimensions_evidence
            return :unknown unless dim_ev.known?

            Array(dim_ev.value).include?(requested) ? :match : :rejected
          end

          # §9.7 step 7 — exact-instance availability.
          # Nil instance (no record) or nil availability → :unknown.
          # :available → :available; :unavailable → :unavailable.
          # :initializing or any other state → :unknown.
          def evaluate_availability(instance:)
            return :unknown if instance.nil?

            avail = instance.availability
            return :unknown if avail.nil?

            case avail.state
            when :available   then :available
            when :unavailable then :unavailable
            else                   :unknown
            end
          end

          # §9.7 step 8 — typed exclusions.
          # attempt_target compares (provider_family, instance_id, model) only.
          # A lane/generation change cannot evade an attempt_target exclusion.
          def evaluate_exclusions(offering:, lane:, exclusions:, requirements:)
            return :clear if exclusions.empty?

            ik     = offering.instance_key
            pf     = ik.provider_family
            iid    = ik.instance_id
            model  = offering.model
            off_id = offering.offering_id

            excluded = exclusions.any? do |excl|
              case excl.target_kind
              when :attempt_target
                t = excl.target
                t.provider_family == pf && t.instance_id == iid && t.model == model
              when :instance
                excl.target == ik
              when :lane
                lane && excl.target == lane.lane_id
              when :offering
                excl.target == off_id
              when :model
                excl.target == model
              when :provider
                excl.target == pf
              when :quota_domain
                qd = offering.quota_domain(operation: requirements.operation)
                qd && excl.target == qd
              else
                false
              end
            end

            excluded ? :excluded : :clear
          end

          # §9.7 step 9 — fleet contract marker.
          # :not_applicable when offering tier is not :fleet.
          # 'exact_offering_v1' → :supported.
          # Absent/empty on complete offering → :legacy.
          # Malformed/unrecognized nonempty → :unknown.
          def evaluate_fleet_contract(offering:)
            return :not_applicable unless offering.tier == :fleet

            contract = offering.metadata[:fleet_execution_contract]
            if contract == 'exact_offering_v1'
              :supported
            elsif contract.nil? || contract.to_s.empty?
              :legacy
            else
              :unknown
            end
          end

          # §9.7 step 10 — configured weight components.
          # Any zero component → :disabled with nil weight_inputs.
          # All positive → :enabled with frozen weight_inputs Hash.
          # Nil lane (unsupported/unknown operation) → :disabled.
          def evaluate_weight(lane:, settings_snapshot:)
            return [:disabled, nil] if lane.nil?

            inputs = settings_snapshot.weight_inputs_for(lane: lane)
            if inputs.values.any?(&:zero?)
              [:disabled, nil]
            else
              [:enabled, inputs]
            end
          end

          # §10.1 preferred-context soft sieve input.
          # True when required_context_budget falls within the configured
          # preferred range for the exact instance — upper-exclusive seam
          # (budget < max), matching the Ranker sieve and the baseline.
          # False when no range is configured or no lane was resolved.
          def evaluate_preferred_context(lane:, requirements:, settings_snapshot:)
            return false if lane.nil?

            range = settings_snapshot.preferred_context_range_for(lane: lane)
            return false if range.nil?

            budget = requirements.required_context_budget
            min_ok = range[:min].nil? || budget >= range[:min]
            max_ok = range[:max].nil? || budget < range[:max]
            min_ok && max_ok
          end
        end
      end
    end
  end
end
