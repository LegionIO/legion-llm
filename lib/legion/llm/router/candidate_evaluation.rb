# frozen_string_literal: true

module Legion
  module LLM
    module Router
      # Immutable per-lane evaluation axes (SSOT v3 §9.6). One CandidateEvaluation
      # is produced for every offering in the captured snapshot. It records the
      # outcome of each hard/soft axis without selecting a winner. `ready?` is the
      # single readiness predicate consumed by the Ranker; unknown is never ready.
      class CandidateEvaluation
        AXES = {
          operation: %i[supported unsupported unknown],
          pin: %i[match mismatch authority_unknown],
          policy: %i[allowed denied],
          capability: %i[supported unsupported unknown],
          context: %i[fits rejected unknown not_applicable],
          dimension: %i[match rejected unknown not_applicable],
          availability: %i[available unavailable unknown],
          exclusion: %i[clear excluded],
          fleet_contract: %i[supported legacy unknown not_applicable],
          weight: %i[enabled disabled]
        }.freeze

        attr_reader :lane, :offering, :instance, :publication_status, :operation_state, :pin_state,
                    :policy_state, :capability_state, :context_state, :dimension_state,
                    :availability_state, :exclusion_state, :fleet_contract_state, :weight_state,
                    :weight_inputs, :preferred_context_match, :reasons

        def initialize(offering:, operation_state:, pin_state:, policy_state:, capability_state:,
                       context_state:, dimension_state:, availability_state:, exclusion_state:,
                       fleet_contract_state:, weight_state:, lane: nil, instance: nil,
                       publication_status: nil, weight_inputs: nil, preferred_context_match: false,
                       reasons: [])
          @lane = lane
          @offering = offering
          @instance = instance
          @publication_status = publication_status
          @operation_state = validate!(:operation, operation_state)
          @pin_state = validate!(:pin, pin_state)
          @policy_state = validate!(:policy, policy_state)
          @capability_state = validate!(:capability, capability_state)
          @context_state = validate!(:context, context_state)
          @dimension_state = validate!(:dimension, dimension_state)
          @availability_state = validate!(:availability, availability_state)
          @exclusion_state = validate!(:exclusion, exclusion_state)
          @fleet_contract_state = validate!(:fleet_contract, fleet_contract_state)
          @weight_state = validate!(:weight, weight_state)
          @weight_inputs = weight_inputs&.freeze
          @preferred_context_match = preferred_context_match
          @reasons = reasons.freeze
          freeze
        end

        # Ready only when an executable lane exists, every applicable hard axis
        # conclusively passes, the exact instance is available, and configured
        # weight is enabled. Any unknown/mismatch/denied/excluded/unavailable fails.
        def ready?
          return false if @lane.nil?
          return false unless @operation_state == :supported
          return false unless @pin_state == :match
          return false unless @policy_state == :allowed
          return false unless @capability_state == :supported
          return false unless %i[fits not_applicable].include?(@context_state)
          return false unless %i[match not_applicable].include?(@dimension_state)
          return false unless @availability_state == :available
          return false unless @exclusion_state == :clear
          return false unless %i[supported not_applicable].include?(@fleet_contract_state)
          return false unless @weight_state == :enabled

          true
        end

        private

        def validate!(axis, value)
          allowed = AXES.fetch(axis)
          unless allowed.include?(value)
            raise ArgumentError, "invalid #{axis} axis value #{value.inspect}; allowed: #{allowed.inspect}"
          end

          value
        end
      end

      # Immutable full evaluation of the captured snapshot (§9.6): every candidate
      # plus every publication status (including initializing scopes with no
      # offering) and the captured inventory generation. RejectionDiagnostics
      # consumes publication_statuses to distinguish 424 (authoritative
      # unsupported) from 425 (incomplete/initializing authority).
      class EvaluationSet
        attr_reader :candidates, :publication_statuses, :inventory_generation

        def initialize(candidates:, publication_statuses:, inventory_generation:)
          @candidates = candidates.freeze
          @publication_statuses = publication_statuses.freeze
          @inventory_generation = inventory_generation
          freeze
        end

        def ready_candidates
          @candidates.select(&:ready?)
        end
      end
    end
  end
end
