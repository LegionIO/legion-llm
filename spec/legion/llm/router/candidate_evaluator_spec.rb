# frozen_string_literal: true

require 'spec_helper'
require 'legion/llm/router/request_requirements'
require 'legion/llm/router/candidate_evaluator'

RSpec.describe Legion::LLM::Router::CandidateEvaluator, :ssot_v3 do
  # SsotV3SnapshotFactory helpers are included via the :ssot_v3 metadata tag.
  # Registry.reset! runs before each example (also via the :ssot_v3 tag).
  # Spec-local SettingsState reset ensures each example gets a fresh snapshot
  # built from spec_helper's canonical default settings.

  before do
    Legion::LLM::Router::SettingsState.reset!
  end

  let(:settings_snapshot) { Legion::LLM::Router::SettingsState.current }
  let(:routing_seed)      { 'ab' * 16 }

  def build_request(routing: {})
    Legion::LLM::Inference::Request.build_for_test(
      routing_seed: routing_seed,
      messages:     [],
      routing:      routing
    )
  end

  def build_requirements(
    operation: :chat,
    caps: [],
    input: 0,
    output: 0,
    dims: nil,
    tier_constraint: nil,
    routing: {}
  )
    Legion::LLM::Router::RequestRequirements.build(
      request:                        build_request(routing: routing),
      operation:                      operation,
      required_capabilities:          caps,
      estimated_input_bound:          input,
      required_output_tokens:         output,
      requested_embedding_dimensions: dims,
      tier_constraint:                tier_constraint
    )
  end

  def call_evaluator(requirements, exclusions, snap)
    described_class.call(
      requirements:      requirements,
      exclusions:        exclusions,
      snapshot:          snap,
      settings_snapshot: settings_snapshot
    )
  end

  # ---------------------------------------------------------------------------
  # §9.7 step 1 — operation evaluation and lane derivation
  # ---------------------------------------------------------------------------

  describe 'supported operation' do
    before do
      activate(
        provider_family: 'vllm',
        instance_id:     'h200',
        drafts:          [offering_draft(model: 'gemma4', supported: %i[chat])]
      )
    end

    it 'produces a candidate with a resolved lane and ready? true' do
      snap   = snapshot
      reqs   = build_requirements
      result = call_evaluator(reqs, [], snap)

      expect(result).to be_a(Legion::LLM::Router::EvaluationSet)
      expect(result.candidates.size).to eq(1)

      candidate = result.candidates.first
      expect(candidate.operation_state).to eq(:supported)
      expect(candidate.lane).not_to be_nil
      expect(candidate.lane).to be_a(Legion::Extensions::Llm::Inventory::LaneRecord)
      expect(candidate.ready?).to be true
    end

    it 'sets inventory_generation from the snapshot' do
      snap   = snapshot
      reqs   = build_requirements
      result = call_evaluator(reqs, [], snap)

      expect(result.inventory_generation).to eq(snap.generation)
    end
  end

  describe 'unsupported operation' do
    before do
      activate(
        provider_family: 'vllm',
        instance_id:     'h200',
        drafts:          [offering_draft(model: 'gemma4', supported: %i[chat], unsupported: %i[embed])]
      )
    end

    it 'produces a candidate with nil lane, operation_state :unsupported, not ready' do
      snap   = snapshot
      reqs   = build_requirements(operation: :embed)
      result = call_evaluator(reqs, [], snap)

      expect(result.candidates.size).to eq(1)
      candidate = result.candidates.first
      expect(candidate.operation_state).to eq(:unsupported)
      expect(candidate.lane).to be_nil
      expect(candidate.ready?).to be false
    end
  end

  # ---------------------------------------------------------------------------
  # §9.7 step 4 — capability evaluation
  # ---------------------------------------------------------------------------

  describe 'capability evaluation' do
    context 'when required capability is absent (unknown evidence)' do
      before do
        # streaming capability not declared in the offering → unknown
        activate(
          provider_family: 'vllm',
          instance_id:     'h200',
          drafts:          [offering_draft(model: 'gemma4', supported: %i[chat], capabilities: {})]
        )
      end

      it 'yields capability_state :unknown, not ready' do
        snap   = snapshot
        reqs   = build_requirements(caps: %i[streaming])
        result = call_evaluator(reqs, [], snap)

        candidate = result.candidates.first
        expect(candidate.capability_state).to eq(:unknown)
        expect(candidate.ready?).to be false
      end
    end

    context 'when required capability is authoritatively unsupported' do
      before do
        activate(
          provider_family: 'vllm',
          instance_id:     'h200',
          drafts:          [offering_draft(
            model: 'gemma4', supported: %i[chat],
            capabilities: { streaming: :unsupported }
          )]
        )
      end

      it 'yields capability_state :unsupported, not ready' do
        snap   = snapshot
        reqs   = build_requirements(caps: %i[streaming])
        result = call_evaluator(reqs, [], snap)

        candidate = result.candidates.first
        expect(candidate.capability_state).to eq(:unsupported)
        expect(candidate.ready?).to be false
      end
    end

    context 'when one required capability is unknown and another is unsupported' do
      before do
        activate(
          provider_family: 'vllm',
          instance_id:     'h200',
          drafts:          [offering_draft(
            model: 'gemma4', supported: %i[chat],
            capabilities: { vision: :unsupported }
            # tools is absent → unknown
          )]
        )
      end

      it 'yields :unknown (unknown takes priority over unsupported)' do
        snap   = snapshot
        reqs   = build_requirements(caps: %i[tools vision])
        result = call_evaluator(reqs, [], snap)

        expect(result.candidates.first.capability_state).to eq(:unknown)
      end
    end

    context 'when all required capabilities are supported' do
      before do
        activate(
          provider_family: 'vllm',
          instance_id:     'h200',
          drafts:          [offering_draft(
            model: 'gemma4', supported: %i[chat],
            capabilities: { streaming: :supported, tools: :supported }
          )]
        )
      end

      it 'yields capability_state :supported' do
        snap   = snapshot
        reqs   = build_requirements(caps: %i[streaming tools])
        result = call_evaluator(reqs, [], snap)

        expect(result.candidates.first.capability_state).to eq(:supported)
      end
    end
  end

  # ---------------------------------------------------------------------------
  # §9.7 step 5 — context budget
  # ---------------------------------------------------------------------------

  describe 'context budget evaluation' do
    context 'when budget fits within the authoritative limit' do
      before do
        # context: 100_000; headroom 900_000 ppm → effective limit 90_000
        activate(
          provider_family: 'vllm',
          instance_id:     'h200',
          drafts:          [offering_draft(model: 'gemma4', supported: %i[chat], context: 100_000)]
        )
      end

      it 'yields context_state :fits' do
        snap   = snapshot
        reqs   = build_requirements(input: 1_000, output: 500)  # budget 1_500 <= 90_000
        result = call_evaluator(reqs, [], snap)

        expect(result.candidates.first.context_state).to eq(:fits)
      end
    end

    context 'when budget exceeds the authoritative limit' do
      before do
        activate(
          provider_family: 'vllm',
          instance_id:     'h200',
          drafts:          [offering_draft(model: 'gemma4', supported: %i[chat], context: 1_000)]
        )
      end

      it 'yields context_state :rejected' do
        snap   = snapshot
        reqs   = build_requirements(input: 5_000, output: 500)  # budget 5_500 > 900
        result = call_evaluator(reqs, [], snap)

        expect(result.candidates.first.context_state).to eq(:rejected)
      end
    end

    context 'when context evidence is absent (unknown)' do
      before do
        # context: nil → unknown ValueEvidence
        activate(
          provider_family: 'vllm',
          instance_id:     'h200',
          drafts:          [offering_draft(model: 'gemma4', supported: %i[chat], context: nil)]
        )
      end

      it 'yields context_state :unknown' do
        snap   = snapshot
        reqs   = build_requirements(input: 1_000, output: 0)
        result = call_evaluator(reqs, [], snap)

        expect(result.candidates.first.context_state).to eq(:unknown)
      end
    end

    context 'when budget is zero (no context requirement)' do
      before do
        activate(
          provider_family: 'vllm',
          instance_id:     'h200',
          drafts:          [offering_draft(model: 'gemma4', supported: %i[chat], context: 100_000)]
        )
      end

      it 'yields context_state :not_applicable' do
        snap   = snapshot
        reqs   = build_requirements(input: 0, output: 0)
        result = call_evaluator(reqs, [], snap)

        expect(result.candidates.first.context_state).to eq(:not_applicable)
      end
    end
  end

  # ---------------------------------------------------------------------------
  # §9.7 step 7 — availability
  # ---------------------------------------------------------------------------

  describe 'availability evaluation' do
    context 'when instance is available' do
      before do
        activate(
          provider_family: 'vllm',
          instance_id:     'h200',
          drafts:          [offering_draft(model: 'gemma4', supported: %i[chat])]
        )
      end

      it 'yields availability_state :available and ready? true' do
        snap      = snapshot
        reqs      = build_requirements
        result    = call_evaluator(reqs, [], snap)
        candidate = result.candidates.first

        expect(candidate.availability_state).to eq(:available)
        expect(candidate.ready?).to be true
      end
    end

    context 'when instance is marked unavailable' do
      before do
        token = activate(
          provider_family: 'vllm',
          instance_id:     'h200',
          drafts:          [offering_draft(model: 'gemma4', supported: %i[chat])]
        )
        mark_unavailable(
          provider_family:    'vllm',
          instance_id:        'h200',
          publisher_token_id: token.publisher_token_id
        )
      end

      it 'yields availability_state :unavailable and ready? false' do
        snap      = snapshot
        reqs      = build_requirements
        result    = call_evaluator(reqs, [], snap)
        candidate = result.candidates.first

        expect(candidate.availability_state).to eq(:unavailable)
        expect(candidate.ready?).to be false
      end
    end
  end

  # ---------------------------------------------------------------------------
  # §9.7 — initializing claim appears in publication_statuses, not candidates
  # ---------------------------------------------------------------------------

  describe 'initializing claim handling' do
    before do
      claim_only(provider_family: 'vllm', instance_id: 'h200')
      activate(
        provider_family: 'vllm',
        instance_id:     'helios1',
        drafts:          [offering_draft(model: 'gemma4', supported: %i[chat])]
      )
    end

    it 'populates publication_statuses with the initializing scope' do
      snap   = snapshot
      reqs   = build_requirements
      result = call_evaluator(reqs, [], snap)

      init_key = instance_key(provider_family: 'vllm', instance_id: 'h200')
      init_ps  = result.publication_statuses.find { |ps| ps.instance_key == init_key }

      expect(init_ps).not_to be_nil
      expect(init_ps.state).to eq(:initializing)
    end

    it 'does not include the initializing scope as a candidate' do
      snap   = snapshot
      reqs   = build_requirements
      result = call_evaluator(reqs, [], snap)

      # Only the activated instance has offerings → only one candidate
      expect(result.candidates.size).to eq(1)
      expect(result.candidates.first.offering.model).to eq('gemma4')
    end

    it 'marks no ready candidates from the initializing scope' do
      snap   = snapshot
      reqs   = build_requirements
      result = call_evaluator(reqs, [], snap)

      expect(result.ready_candidates.size).to eq(1)
    end
  end

  # ---------------------------------------------------------------------------
  # §9.7 step 8 — typed exclusions
  # ---------------------------------------------------------------------------

  describe 'attempt_target exclusion' do
    before do
      activate(
        provider_family: 'vllm',
        instance_id:     'h200',
        drafts:          [offering_draft(model: 'gemma4', supported: %i[chat])]
      )
    end

    it 'marks exclusion_state :excluded and not ready' do
      snap   = snapshot
      reqs   = build_requirements
      atk    = Legion::Extensions::Llm::Routing::AttemptTargetKey.new(
        provider_family: :vllm,
        instance_id:     'h200',
        model:           'gemma4'
      )
      excl = Legion::Extensions::Llm::Routing::Exclusion.new(
        target_kind: :attempt_target,
        target:      atk,
        reason:      'attempt_consumed',
        evidence:    { attempt_number: 1 },
        lifetime:    :request
      )
      result    = call_evaluator(reqs, [excl], snap)
      candidate = result.candidates.first

      expect(candidate.exclusion_state).to eq(:excluded)
      expect(candidate.ready?).to be false
    end

    it 'clears a non-matching attempt_target' do
      snap   = snapshot
      reqs   = build_requirements
      # Different model → does not match gemma4
      atk    = Legion::Extensions::Llm::Routing::AttemptTargetKey.new(
        provider_family: :vllm,
        instance_id:     'h200',
        model:           'llama3'
      )
      excl = Legion::Extensions::Llm::Routing::Exclusion.new(
        target_kind: :attempt_target,
        target:      atk,
        reason:      'attempt_consumed',
        evidence:    {},
        lifetime:    :request
      )
      result    = call_evaluator(reqs, [excl], snap)
      candidate = result.candidates.first

      expect(candidate.exclusion_state).to eq(:clear)
    end
  end

  # ---------------------------------------------------------------------------
  # §9.7 N×N — same model on two instances → two independent candidates
  # ---------------------------------------------------------------------------

  describe 'N×N: same model on two instances' do
    before do
      activate(
        provider_family: 'vllm',
        instance_id:     'h200',
        drafts:          [offering_draft(model: 'gemma4', supported: %i[chat])]
      )
      activate(
        provider_family: 'vllm',
        instance_id:     'helios1',
        drafts:          [offering_draft(model: 'gemma4', supported: %i[chat])]
      )
    end

    it 'produces two independent candidates for the same model across instances' do
      snap   = snapshot
      reqs   = build_requirements
      result = call_evaluator(reqs, [], snap)

      expect(result.candidates.size).to eq(2)
      instance_ids = result.candidates.map { |c| c.offering.instance_key.instance_id }.sort
      expect(instance_ids).to eq(%w[h200 helios1])
    end

    it 'makes both candidates ready independently' do
      snap   = snapshot
      reqs   = build_requirements
      result = call_evaluator(reqs, [], snap)

      expect(result.ready_candidates.size).to eq(2)
    end

    it 'excludes only the targeted instance when an attempt_target exclusion is present' do
      snap   = snapshot
      reqs   = build_requirements
      atk    = Legion::Extensions::Llm::Routing::AttemptTargetKey.new(
        provider_family: :vllm,
        instance_id:     'h200',
        model:           'gemma4'
      )
      excl = Legion::Extensions::Llm::Routing::Exclusion.new(
        target_kind: :attempt_target,
        target:      atk,
        reason:      'attempt_consumed',
        evidence:    {},
        lifetime:    :request
      )
      result     = call_evaluator(reqs, [excl], snap)
      h200       = result.candidates.find { |c| c.offering.instance_key.instance_id == 'h200' }
      helios1    = result.candidates.find { |c| c.offering.instance_key.instance_id == 'helios1' }

      expect(h200.exclusion_state).to eq(:excluded)
      expect(helios1.exclusion_state).to eq(:clear)
      expect(result.ready_candidates.size).to eq(1)
      expect(result.ready_candidates.first.offering.instance_key.instance_id).to eq('helios1')
    end
  end

  # ---------------------------------------------------------------------------
  # §9.7 step 2 — pin evaluation
  # ---------------------------------------------------------------------------

  describe 'provider/model pin filtering' do
    before do
      activate(
        provider_family: 'anthropic',
        instance_id:     'cloud1',
        drafts:          [offering_draft(model: 'claude-3', supported: %i[chat])]
      )
      activate(
        provider_family: 'vllm',
        instance_id:     'h200',
        drafts:          [offering_draft(model: 'gemma4', supported: %i[chat])]
      )
    end

    it 'marks only the matching offering as :match when model is pinned' do
      snap   = snapshot
      reqs   = build_requirements(routing: { model: 'claude-3' })
      result = call_evaluator(reqs, [], snap)

      claude = result.candidates.find { |c| c.offering.model == 'claude-3' }
      gemma  = result.candidates.find { |c| c.offering.model == 'gemma4' }

      expect(claude.pin_state).to eq(:match)
      expect(gemma.pin_state).to eq(:mismatch)
    end

    it 'marks the pinned candidate ready and the mismatched one not ready' do
      snap   = snapshot
      reqs   = build_requirements(routing: { model: 'claude-3' })
      result = call_evaluator(reqs, [], snap)

      claude = result.candidates.find { |c| c.offering.model == 'claude-3' }
      gemma  = result.candidates.find { |c| c.offering.model == 'gemma4' }

      expect(claude.ready?).to be true
      expect(gemma.ready?).to be false
    end

    it 'marks only the matching offering as :match when provider is pinned' do
      snap   = snapshot
      reqs   = build_requirements(routing: { provider: 'anthropic' })
      result = call_evaluator(reqs, [], snap)

      claude = result.candidates.find { |c| c.offering.model == 'claude-3' }
      gemma  = result.candidates.find { |c| c.offering.model == 'gemma4' }

      expect(claude.pin_state).to eq(:match)
      expect(gemma.pin_state).to eq(:mismatch)
    end
  end

  # ---------------------------------------------------------------------------
  # §9.7 step 9 — fleet contract
  # ---------------------------------------------------------------------------

  describe 'fleet contract evaluation' do
    context 'with a valid fleet_execution_contract marker' do
      before do
        activate(
          provider_family: 'vllm',
          instance_id:     'fleet1',
          drafts:          [offering_draft(
            model: 'gemma4', supported: %i[chat], tier: :fleet,
            metadata: { fleet_execution_contract: 'exact_offering_v1' }
          )]
        )
      end

      it 'yields fleet_contract_state :supported' do
        snap   = snapshot
        reqs   = build_requirements
        result = call_evaluator(reqs, [], snap)

        expect(result.candidates.first.fleet_contract_state).to eq(:supported)
      end
    end

    context 'with no fleet_execution_contract on a fleet offering (legacy)' do
      before do
        activate(
          provider_family: 'vllm',
          instance_id:     'fleet2',
          drafts:          [offering_draft(
            model: 'gemma4', supported: %i[chat], tier: :fleet, metadata: {}
          )]
        )
      end

      it 'yields fleet_contract_state :legacy' do
        snap   = snapshot
        reqs   = build_requirements
        result = call_evaluator(reqs, [], snap)

        expect(result.candidates.first.fleet_contract_state).to eq(:legacy)
      end
    end

    context 'with a malformed/unrecognized fleet_execution_contract value' do
      before do
        activate(
          provider_family: 'vllm',
          instance_id:     'fleet3',
          drafts:          [offering_draft(
            model: 'gemma4', supported: %i[chat], tier: :fleet,
            metadata: { fleet_execution_contract: 'unknown_contract_v99' }
          )]
        )
      end

      it 'yields fleet_contract_state :unknown' do
        snap   = snapshot
        reqs   = build_requirements
        result = call_evaluator(reqs, [], snap)

        expect(result.candidates.first.fleet_contract_state).to eq(:unknown)
      end
    end

    context 'with a non-fleet offering' do
      before do
        activate(
          provider_family: 'vllm',
          instance_id:     'direct1',
          drafts:          [offering_draft(
            model: 'gemma4', supported: %i[chat], tier: :direct
          )]
        )
      end

      it 'yields fleet_contract_state :not_applicable' do
        snap   = snapshot
        reqs   = build_requirements
        result = call_evaluator(reqs, [], snap)

        expect(result.candidates.first.fleet_contract_state).to eq(:not_applicable)
      end
    end
  end

  # ---------------------------------------------------------------------------
  # §9.7 step 6 — embedding dimensions
  # ---------------------------------------------------------------------------

  describe 'embedding dimensions evaluation' do
    context 'when dimensions are not requested' do
      before do
        activate(
          provider_family: 'vllm',
          instance_id:     'h200',
          drafts:          [offering_draft(
            model: 'embed-model', supported: %i[embed],
            capabilities: { embedding: :supported }, embedding_dimensions: [1536]
          )]
        )
      end

      it 'yields dimension_state :not_applicable' do
        snap   = snapshot
        reqs   = build_requirements(operation: :embed, caps: %i[embedding])
        result = call_evaluator(reqs, [], snap)

        expect(result.candidates.first.dimension_state).to eq(:not_applicable)
      end
    end

    context 'when requested dimensions match authoritative evidence' do
      before do
        activate(
          provider_family: 'vllm',
          instance_id:     'h200',
          drafts:          [offering_draft(
            model: 'embed-model', supported: %i[embed],
            capabilities: { embedding: :supported }, embedding_dimensions: [1536]
          )]
        )
      end

      it 'yields dimension_state :match' do
        snap   = snapshot
        reqs   = build_requirements(operation: :embed, caps: %i[embedding], dims: 1536)
        result = call_evaluator(reqs, [], snap)

        expect(result.candidates.first.dimension_state).to eq(:match)
      end
    end

    context 'when requested dimensions mismatch authoritative evidence' do
      before do
        activate(
          provider_family: 'vllm',
          instance_id:     'h200',
          drafts:          [offering_draft(
            model: 'embed-model', supported: %i[embed],
            capabilities: { embedding: :supported }, embedding_dimensions: [768]
          )]
        )
      end

      it 'yields dimension_state :rejected' do
        snap   = snapshot
        reqs   = build_requirements(operation: :embed, caps: %i[embedding], dims: 1536)
        result = call_evaluator(reqs, [], snap)

        expect(result.candidates.first.dimension_state).to eq(:rejected)
        expect(result.candidates.first.ready?).to be false
      end
    end
  end

  # ---------------------------------------------------------------------------
  # Empty snapshot
  # ---------------------------------------------------------------------------

  describe 'empty snapshot' do
    it 'returns an EvaluationSet with no candidates and no publication_statuses' do
      snap   = snapshot
      reqs   = build_requirements
      result = call_evaluator(reqs, [], snap)

      expect(result.candidates).to be_empty
      expect(result.publication_statuses).to be_empty
    end
  end
end
