# frozen_string_literal: true

module Legion
  module LLM
    module Router
      # Total typed no-candidate reduction (SSOT v3 §11). Called only when
      # Ranker returns nil (no ready candidate). Applies the exact ordered
      # partition to produce the single most specific Rejection.
      #
      # NEVER infers :attempts_exhausted — RoutingSession constructs that
      # before candidate evaluation begins and it is not a candidate-set verdict.
      # NEVER infers :stale_selection — that is an AttemptContext/RoutingSession
      # concern, not a no-candidate signal.
      module RejectionDiagnostics
        extend Legion::Logging::Helper

        SEED_PATTERN = /\A[0-9a-f]{32}\z/
        private_constant :SEED_PATTERN

        # rubocop:disable Metrics/AbcSize
        def self.call(requirements:, evaluation_set:, snapshot:, **)
          candidates   = evaluation_set.candidates
          pub_statuses = evaluation_set.publication_statuses
          gen          = evaluation_set.inventory_generation
          counts       = build_counts(candidates, pub_statuses)
          pins         = build_explicit_pins(requirements)

          # ---------------------------------------------------------------- #
          # Step 0 — malformed/missing routing context                        #
          # Guard: server-created routing_seed absent or not 32-char hex.    #
          # ---------------------------------------------------------------- #
          seed = requirements.routing_seed
          unless seed.is_a?(String) && seed.match?(SEED_PATTERN)
            log.warn('[llm][rejection_diagnostics] action=diagnose result=invalid_routing_context')
            return rejection(:invalid_routing_context, 500,
                             'routing context absent or malformed', gen, counts, pins)
          end

          # ---------------------------------------------------------------- #
          # Steps 1–2 — explicit-pin checks (skipped when no pins supplied)  #
          # ---------------------------------------------------------------- #
          if pins.any?
            # Step 1 — pin proven absent: every candidate mismatches and every
            # relevant publication scope is complete (authoritative evidence
            # proves the pin does not exist).
            if candidates.any? && candidates.all? { |c| c.pin_state == :mismatch } && (pub_statuses.empty? || pub_statuses.all? { |s| s.state == :complete })
              log.debug('[llm][rejection_diagnostics] action=diagnose result=invalid_request ' \
                        "reason=pin_nonexistent pins=#{pins.keys.join(',')}")
              return rejection(:invalid_request, 400,
                               'explicit pin not found in any complete publication scope',
                               gen, counts, pins)
            end

            # Step 2 — pin not provable: no complete scope exists; cannot
            # confirm or deny the pinned identity.
            unless pub_statuses.any? { |s| s.state == :complete }
              log.debug('[llm][rejection_diagnostics] action=diagnose result=too_early ' \
                        'reason=pin_authority_incomplete')
              return rejection(:too_early, 425,
                               'explicit pin resolution blocked; all publication scopes are initializing or absent',
                               gen, counts, pins)
            end
          end

          # ---------------------------------------------------------------- #
          # Cold/empty catalog — no candidates regardless of cause            #
          # ---------------------------------------------------------------- #
          if candidates.empty?
            log.debug('[llm][rejection_diagnostics] action=diagnose result=too_early ' \
                      "reason=cold_catalog pub_scopes=#{pub_statuses.size}")
            return rejection(:too_early, 425,
                             'no selectable candidates; catalog is cold or all scopes are initializing',
                             gen, counts, pins)
          end

          # ---------------------------------------------------------------- #
          # Step 3 — policy_denied 403                                        #
          # Every candidate is policy denied or weight disabled.              #
          # ---------------------------------------------------------------- #
          if candidates.all? { |c| c.policy_state == :denied || c.weight_state == :disabled }
            log.debug('[llm][rejection_diagnostics] action=diagnose result=policy_denied ' \
                      "count=#{candidates.size}")
            return rejection(:policy_denied, 403,
                             'all candidates are policy denied or weight disabled',
                             gen, counts, pins)
          end

          # "Otherwise relevant" from step 4 onwards: not policy denied, not disabled.
          policy_eligible = candidates.reject { |c| c.policy_state == :denied || c.weight_state == :disabled }

          # ---------------------------------------------------------------- #
          # Step 4 — failed_dependency 424                                    #
          # Complete catalog; every policy-eligible candidate conclusively    #
          # lacks the requested operation or capability (no :unknown among    #
          # the relevant op/cap axes).                                        #
          # ---------------------------------------------------------------- #
          all_scopes_complete    = pub_statuses.empty? || pub_statuses.all? { |s| s.state == :complete }
          has_op_cap_unknown     = policy_eligible.any? do |c|
            c.operation_state == :unknown || c.capability_state == :unknown
          end
          all_op_cap_unsupported = policy_eligible.all? do |c|
            c.operation_state == :unsupported || c.capability_state == :unsupported
          end

          if all_scopes_complete && all_op_cap_unsupported && !has_op_cap_unknown
            log.debug('[llm][rejection_diagnostics] action=diagnose result=failed_dependency ' \
                      "count=#{policy_eligible.size}")
            return rejection(:failed_dependency, 424,
                             'all eligible candidates conclusively lack required operation or capability',
                             gen, counts, pins)
          end

          # ---------------------------------------------------------------- #
          # Step 5 — too_early 425 (unknown evidence)                         #
          # Any potentially eligible candidate has unknown evidence on any   #
          # hard-filter axis: operation, capability, context, dimension,     #
          # availability, or fleet contract.                                  #
          # ---------------------------------------------------------------- #
          has_any_unknown = policy_eligible.any? do |c|
            c.operation_state == :unknown ||
              c.capability_state     == :unknown ||
              c.context_state        == :unknown ||
              c.dimension_state      == :unknown ||
              c.availability_state   == :unknown ||
              c.fleet_contract_state == :unknown
          end

          if has_any_unknown
            log.debug('[llm][rejection_diagnostics] action=diagnose result=too_early reason=unknown_evidence')
            return rejection(:too_early, 425,
                             'some candidates have unknown evidence; system may still be initializing',
                             gen, counts, pins)
          end

          # ---------------------------------------------------------------- #
          # Step 6 — service_unavailable 503                                  #
          # Every conclusively capable/fit candidate is on an unavailable    #
          # instance. "Conclusively fit" = authoritative supported for all   #
          # evidence axes; only availability blocks dispatch.                #
          # ---------------------------------------------------------------- #
          conclusively_fit = policy_eligible.select do |c|
            c.operation_state == :supported &&
              c.capability_state == :supported &&
              %i[fits not_applicable].include?(c.context_state) &&
              %i[match not_applicable].include?(c.dimension_state)
          end

          if conclusively_fit.any? && conclusively_fit.all? { |c| c.availability_state == :unavailable }
            log.debug('[llm][rejection_diagnostics] action=diagnose result=service_unavailable ' \
                      "count=#{conclusively_fit.size}")
            return rejection(:service_unavailable, 503,
                             'all capable candidates are on unavailable instances',
                             gen, counts, pins)
          end

          # ---------------------------------------------------------------- #
          # Step 7 — context_rejected 400                                     #
          # A conclusive context or dimension constraint blocks selection.   #
          # Only when an authoritative context/dimension rejection is the    #
          # actual cause — NOT when the sole blocker is request-local         #
          # exclusion (a consumed attempt identity).                          #
          # ---------------------------------------------------------------- #
          if policy_eligible.any? { |c| c.context_state == :rejected || c.dimension_state == :rejected }
            log.debug('[llm][rejection_diagnostics] action=diagnose result=context_rejected ' \
                      "count=#{policy_eligible.size}")
            return rejection(:context_rejected, 400,
                             'all candidates fail context or dimension constraints',
                             gen, counts, pins)
          end

          # ---------------------------------------------------------------- #
          # Step 8 — service_unavailable 503 (retriable)                      #
          # Candidates were otherwise eligible (capable, fit, not policy-     #
          # denied, no unknown evidence) but every one is request-locally     #
          # excluded (its exact provider+instance+model was already consumed  #
          # this request) or on an unavailable instance. This is the "tried   #
          # every eligible target, none left" state — retriable, never a      #
          # 400 caller error and never a fabricated default. Maps to 503      #
          # (native/OpenAI) / 529 (Anthropic) with Retry-After.               #
          # ---------------------------------------------------------------- #
          log.debug('[llm][rejection_diagnostics] action=diagnose result=service_unavailable ' \
                    "reason=all_eligible_consumed_or_unavailable count=#{policy_eligible.size}")
          rejection(:service_unavailable, 503,
                    'all eligible candidates are consumed or unavailable for this request',
                    gen, counts, pins)
        end
        # rubocop:enable Metrics/AbcSize

        # ------------------------------------------------------------------ #
        # Private helpers                                                      #
        # ------------------------------------------------------------------ #

        def self.rejection(kind, http_status, reason, gen, counts, pins)
          Legion::Extensions::Llm::Routing::Rejection.new(
            kind:                 kind,
            reason:               reason,
            inventory_generation: gen,
            candidate_counts:     counts,
            explicit_pins:        pins,
            http_status:          http_status
          )
        end
        private_class_method :rejection

        # Frozen Symbol-keyed count of each axis state and publication scope
        # state across the full candidate + publication-status set. Diagnostic
        # only; never drives a second selection.
        def self.build_counts(candidates, pub_statuses)
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
        private_class_method :build_counts

        # Sanitized hash of the non-nil routing pins from the requirements.
        # Only safe to include (no credentials or routing-seed values).
        def self.build_explicit_pins(requirements)
          {
            provider: requirements.provider_pin,
            instance: requirements.instance_pin,
            model:    requirements.model_pin,
            tier:     requirements.tier_constraint
          }.compact.freeze
        end
        private_class_method :build_explicit_pins
      end
    end
  end
end
