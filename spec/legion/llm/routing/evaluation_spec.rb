# frozen_string_literal: true

require 'spec_helper'
require 'legion/llm/routing/evaluation'

RSpec.describe Legion::LLM::Routing::CandidateEvaluation do
  let(:lane_double) { instance_double('Legion::Extensions::Llm::Inventory::LaneRecord') }

  # The minimal set of kwargs that produces a ready? == true evaluation.
  def ready_kwargs(overrides = {})
    {
      lane:                 lane_double,
      operation_state:      :supported,
      pin_state:            :match,
      policy_state:         :allowed,
      capability_state:     :supported,
      context_state:        :fits,
      dimension_state:      :match,
      availability_state:   :available,
      exclusion_state:      :clear,
      fleet_contract_state: :supported,
      weight_state:         :enabled
    }.merge(overrides)
  end

  # -------------------------------------------------------------------
  # §7.6 — AXES validation
  # -------------------------------------------------------------------

  describe '#initialize' do
    it 'accepts all valid axis values and freezes the record' do
      eval_record = described_class.new(**ready_kwargs)

      expect(eval_record).to be_frozen
      expect(eval_record.lane).to eq(lane_double)
      expect(eval_record.operation_state).to eq(:supported)
    end

    it 'stores optional instance, publication_status, weight_inputs, and reasons' do
      eval_record = described_class.new(
        **ready_kwargs,
        instance:           :some_instance,
        publication_status: :active,
        weight_inputs:      { tier: 100, provider: 80 },
        reasons:            ['pin match']
      )

      expect(eval_record.instance).to eq(:some_instance)
      expect(eval_record.publication_status).to eq(:active)
      expect(eval_record.weight_inputs).to eq({ tier: 100, provider: 80 })
      expect(eval_record.weight_inputs).to be_frozen
      expect(eval_record.reasons).to eq(['pin match'])
      expect(eval_record.reasons).to be_frozen
    end

    Legion::LLM::Routing::CandidateEvaluation::AXES.each do |axis, allowed_values|
      context "#{axis} axis" do
        it 'raises ArgumentError for an out-of-domain value' do
          bad_value = :completely_bogus
          kwarg_key = :"#{axis}_state"

          expect do
            described_class.new(**ready_kwargs(kwarg_key => bad_value))
          end.to raise_error(
            ArgumentError,
            "invalid #{axis} axis value :completely_bogus; allowed: #{allowed_values.inspect}"
          )
        end

        it "accepts all declared domain values: #{allowed_values.inspect}" do
          kwarg_key = :"#{axis}_state"
          allowed_values.each do |val|
            expect do
              described_class.new(**ready_kwargs(kwarg_key => val))
            end.not_to raise_error
          end
        end
      end
    end
  end

  # -------------------------------------------------------------------
  # §7.6 — ready? predicate
  # -------------------------------------------------------------------

  describe '#ready?' do
    context 'when all axes pass' do
      it 'returns true' do
        eval_record = described_class.new(**ready_kwargs)
        expect(eval_record.ready?).to be true
      end

      it 'returns true with context_state :not_applicable' do
        eval_record = described_class.new(**ready_kwargs(context_state: :not_applicable))
        expect(eval_record.ready?).to be true
      end

      it 'returns true with dimension_state :not_applicable' do
        eval_record = described_class.new(**ready_kwargs(dimension_state: :not_applicable))
        expect(eval_record.ready?).to be true
      end

      it 'returns true with fleet_contract_state :not_applicable' do
        eval_record = described_class.new(**ready_kwargs(fleet_contract_state: :not_applicable))
        expect(eval_record.ready?).to be true
      end
    end

    context 'when lane is nil' do
      it 'returns false' do
        eval_record = described_class.new(**ready_kwargs(lane: nil))
        expect(eval_record.ready?).to be false
      end
    end

    context 'when operation_state is :unsupported' do
      it 'returns false' do
        eval_record = described_class.new(**ready_kwargs(operation_state: :unsupported))
        expect(eval_record.ready?).to be false
      end
    end

    context 'when operation_state is :unknown' do
      it 'returns false' do
        eval_record = described_class.new(**ready_kwargs(operation_state: :unknown))
        expect(eval_record.ready?).to be false
      end
    end

    context 'when pin_state is :mismatch' do
      it 'returns false' do
        eval_record = described_class.new(**ready_kwargs(pin_state: :mismatch))
        expect(eval_record.ready?).to be false
      end
    end

    context 'when pin_state is :authority_unknown' do
      it 'returns false' do
        eval_record = described_class.new(**ready_kwargs(pin_state: :authority_unknown))
        expect(eval_record.ready?).to be false
      end
    end

    context 'when policy_state is :denied' do
      it 'returns false' do
        eval_record = described_class.new(**ready_kwargs(policy_state: :denied))
        expect(eval_record.ready?).to be false
      end
    end

    context 'when capability_state is :unsupported' do
      it 'returns false' do
        eval_record = described_class.new(**ready_kwargs(capability_state: :unsupported))
        expect(eval_record.ready?).to be false
      end
    end

    context 'when capability_state is :unknown' do
      it 'returns false' do
        eval_record = described_class.new(**ready_kwargs(capability_state: :unknown))
        expect(eval_record.ready?).to be false
      end
    end

    context 'when context_state is :rejected' do
      it 'returns false' do
        eval_record = described_class.new(**ready_kwargs(context_state: :rejected))
        expect(eval_record.ready?).to be false
      end
    end

    context 'when context_state is :unknown' do
      it 'returns false' do
        eval_record = described_class.new(**ready_kwargs(context_state: :unknown))
        expect(eval_record.ready?).to be false
      end
    end

    context 'when dimension_state is :rejected' do
      it 'returns false' do
        eval_record = described_class.new(**ready_kwargs(dimension_state: :rejected))
        expect(eval_record.ready?).to be false
      end
    end

    context 'when dimension_state is :unknown' do
      it 'returns false' do
        eval_record = described_class.new(**ready_kwargs(dimension_state: :unknown))
        expect(eval_record.ready?).to be false
      end
    end

    context 'when availability_state is :unavailable' do
      it 'returns false' do
        eval_record = described_class.new(**ready_kwargs(availability_state: :unavailable))
        expect(eval_record.ready?).to be false
      end
    end

    context 'when availability_state is :unknown' do
      it 'returns false' do
        eval_record = described_class.new(**ready_kwargs(availability_state: :unknown))
        expect(eval_record.ready?).to be false
      end
    end

    context 'when exclusion_state is :excluded' do
      it 'returns false' do
        eval_record = described_class.new(**ready_kwargs(exclusion_state: :excluded))
        expect(eval_record.ready?).to be false
      end
    end

    context 'when fleet_contract_state is :legacy' do
      it 'returns false' do
        eval_record = described_class.new(**ready_kwargs(fleet_contract_state: :legacy))
        expect(eval_record.ready?).to be false
      end
    end

    context 'when fleet_contract_state is :unknown' do
      it 'returns false' do
        eval_record = described_class.new(**ready_kwargs(fleet_contract_state: :unknown))
        expect(eval_record.ready?).to be false
      end
    end

    context 'when weight_state is :disabled' do
      it 'returns false' do
        eval_record = described_class.new(**ready_kwargs(weight_state: :disabled))
        expect(eval_record.ready?).to be false
      end
    end
  end
end

RSpec.describe Legion::LLM::Routing::EvaluationSet do
  let(:lane_double) { instance_double('Legion::Extensions::Llm::Inventory::LaneRecord') }

  def build_candidate(ready:)
    kwargs = {
      lane:                 ready ? lane_double : nil,
      operation_state:      :supported,
      pin_state:            :match,
      policy_state:         :allowed,
      capability_state:     :supported,
      context_state:        :fits,
      dimension_state:      :match,
      availability_state:   :available,
      exclusion_state:      :clear,
      fleet_contract_state: :supported,
      weight_state:         :enabled
    }
    # A nil lane makes it not-ready; otherwise it's fully ready.
    Legion::LLM::Routing::CandidateEvaluation.new(**kwargs)
  end

  describe '#initialize' do
    it 'freezes candidates and publication_statuses' do
      candidates = [build_candidate(ready: true)]
      pub_statuses = [{ instance_key: 'vllm/h200', state: :active }]

      set = described_class.new(
        candidates:           candidates,
        publication_statuses: pub_statuses,
        inventory_generation: 42
      )

      expect(set.candidates).to be_frozen
      expect(set.publication_statuses).to be_frozen
      expect(set.inventory_generation).to eq(42)
      expect(set).to be_frozen
    end
  end

  describe '#ready_candidates' do
    it 'selects only candidates where ready? is true' do
      ready_one   = build_candidate(ready: true)
      ready_two   = build_candidate(ready: true)
      not_ready   = Legion::LLM::Routing::CandidateEvaluation.new(
        lane:                 lane_double,
        operation_state:      :unsupported,
        pin_state:            :match,
        policy_state:         :allowed,
        capability_state:     :supported,
        context_state:        :fits,
        dimension_state:      :match,
        availability_state:   :available,
        exclusion_state:      :clear,
        fleet_contract_state: :supported,
        weight_state:         :enabled
      )

      set = described_class.new(
        candidates:           [ready_one, not_ready, ready_two],
        publication_statuses: [],
        inventory_generation: 7
      )

      expect(set.ready_candidates).to contain_exactly(ready_one, ready_two)
    end

    it 'returns an empty array when no candidates are ready' do
      not_ready = Legion::LLM::Routing::CandidateEvaluation.new(
        lane:                 nil,
        operation_state:      :supported,
        pin_state:            :match,
        policy_state:         :allowed,
        capability_state:     :supported,
        context_state:        :fits,
        dimension_state:      :match,
        availability_state:   :available,
        exclusion_state:      :clear,
        fleet_contract_state: :supported,
        weight_state:         :enabled
      )

      set = described_class.new(
        candidates:           [not_ready],
        publication_statuses: [],
        inventory_generation: 1
      )

      expect(set.ready_candidates).to be_empty
    end
  end
end
