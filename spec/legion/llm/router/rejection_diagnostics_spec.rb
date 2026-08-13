# frozen_string_literal: true

require 'spec_helper'
require 'legion/llm/router/request_requirements'
require 'legion/llm/router/candidate_evaluation'
require 'legion/llm/router/rejection_diagnostics'

RSpec.describe Legion::LLM::Router::RejectionDiagnostics, :ssot_v3 do
  Inv = Legion::Extensions::Llm::Inventory unless defined?(Inv)

  # ---------------------------------------------------------------------------
  # Helpers
  # ---------------------------------------------------------------------------

  # Minimal stand-in for an Offering — CandidateEvaluation stores it but we
  # never call methods on it from RejectionDiagnostics.
  def stub_offering
    Struct.new(:offering_id).new('stub-offering-1').freeze
  end

  # Build a PublicationStatus for a fresh InstanceKey (provider_family + instance_id
  # come from the ssot_v3 snapshot-factory helper, so Registry tracks it if needed).
  def pub_status(state:, provider_family: 'vllm', instance_id: 'h200')
    key = instance_key(provider_family: provider_family, instance_id: instance_id)
    Inv::PublicationStatus.new(
      instance_key: key, state: state, publisher_token_id: nil, published_sequence: nil
    )
  end

  # Build a CandidateEvaluation with all-green defaults; callers override axes.
  def candidate(**axes)
    Legion::LLM::Router::CandidateEvaluation.new(
      offering:             stub_offering,
      operation_state:      :supported,
      pin_state:            :match,
      policy_state:         :allowed,
      capability_state:     :supported,
      context_state:        :not_applicable,
      dimension_state:      :not_applicable,
      availability_state:   :available,
      exclusion_state:      :clear,
      fleet_contract_state: :not_applicable,
      weight_state:         :enabled, **axes
    )
  end

  # Assemble an EvaluationSet from raw arrays.
  def eval_set(candidates: [], statuses: [], gen: 1)
    Legion::LLM::Router::EvaluationSet.new(
      candidates:           candidates,
      publication_statuses: statuses,
      inventory_generation: gen
    )
  end

  # Build a valid RequestRequirements (no pins, no tier constraint).
  def requirements
    req = Legion::LLM::Inference::Request.build_for_test(routing_seed: 'ab' * 16, messages: [])
    Legion::LLM::Router::RequestRequirements.build(
      request: req, operation: :chat, required_capabilities: [],
      estimated_input_bound: 10, required_output_tokens: 0
    )
  end

  # Shorthand: call the module under test with a hand-built EvaluationSet.
  def diagnose(candidates: [], statuses: [], gen: 1)
    described_class.call(
      requirements:   requirements,
      evaluation_set: eval_set(candidates: candidates, statuses: statuses, gen: gen),
      snapshot:       snapshot
    )
  end

  # ---------------------------------------------------------------------------
  # Ordered partition — one example per kind
  # ---------------------------------------------------------------------------

  describe 'Step 0 — invalid_routing_context' do
    it 'is proved in RequestRequirements itself (bad seed → InvalidRoutingContext raised before call)' do
      expect do
        Legion::LLM::Router::RequestRequirements.build(
          request: Legion::LLM::Inference::Request.build_for_test(
            routing_seed: 'ab' * 16, messages: []
          ),
          operation: :chat, required_capabilities: [],
          estimated_input_bound: 10, required_output_tokens: 0
        )
      end.not_to raise_error
    end
  end

  describe 'cold / empty catalog (no candidates, no statuses)' do
    it 'returns :too_early with http_status 425' do
      r = diagnose
      expect(r.kind).to eq(:too_early)
      expect(r.http_status).to eq(425)
    end
  end

  describe 'Step 2 — too_early: initializing scope, no candidates' do
    it 'returns :too_early with http_status 425' do
      r = diagnose(statuses: [pub_status(state: :initializing)])
      expect(r.kind).to eq(:too_early)
      expect(r.http_status).to eq(425)
    end
  end

  describe 'Step 3 — policy_denied' do
    it 'all candidates policy denied → :policy_denied 403' do
      cands = [candidate(policy_state: :denied), candidate(policy_state: :denied)]
      r = diagnose(candidates: cands, statuses: [pub_status(state: :complete)])
      expect(r.kind).to eq(:policy_denied)
      expect(r.http_status).to eq(403)
    end

    it 'all candidates weight disabled → :policy_denied 403' do
      cands = [candidate(weight_state: :disabled), candidate(weight_state: :disabled)]
      r = diagnose(candidates: cands, statuses: [pub_status(state: :complete)])
      expect(r.kind).to eq(:policy_denied)
      expect(r.http_status).to eq(403)
    end
  end

  describe 'Step 4 — failed_dependency' do
    it 'all operation unsupported, complete scopes, no unknown → :failed_dependency 424' do
      cands = [candidate(operation_state: :unsupported), candidate(operation_state: :unsupported)]
      r = diagnose(candidates: cands, statuses: [pub_status(state: :complete)])
      expect(r.kind).to eq(:failed_dependency)
      expect(r.http_status).to eq(424)
    end

    it 'all capability unsupported, complete scopes, no unknown → :failed_dependency 424' do
      cands = [candidate(capability_state: :unsupported), candidate(capability_state: :unsupported)]
      r = diagnose(candidates: cands, statuses: [pub_status(state: :complete)])
      expect(r.kind).to eq(:failed_dependency)
      expect(r.http_status).to eq(424)
    end

    it 'unknown op evidence prevents failed_dependency → falls to too_early instead' do
      cands = [candidate(operation_state: :unknown), candidate(operation_state: :unsupported)]
      r = diagnose(candidates: cands, statuses: [pub_status(state: :complete)])
      expect(r.kind).to eq(:too_early)
    end
  end

  describe 'Step 5 — too_early: unknown evidence on eligible candidates' do
    it 'unknown capability state → :too_early 425' do
      cands = [candidate(capability_state: :unknown)]
      r = diagnose(candidates: cands, statuses: [pub_status(state: :complete)])
      expect(r.kind).to eq(:too_early)
      expect(r.http_status).to eq(425)
    end

    it 'unknown availability state → :too_early 425' do
      cands = [candidate(availability_state: :unknown)]
      r = diagnose(candidates: cands, statuses: [pub_status(state: :complete)])
      expect(r.kind).to eq(:too_early)
      expect(r.http_status).to eq(425)
    end
  end

  describe 'Step 6 — service_unavailable' do
    it 'all conclusively-fit candidates unavailable → :service_unavailable 503' do
      cands = [
        candidate(availability_state: :unavailable),
        candidate(availability_state: :unavailable)
      ]
      r = diagnose(candidates: cands, statuses: [pub_status(state: :complete)])
      expect(r.kind).to eq(:service_unavailable)
      expect(r.http_status).to eq(503)
    end

    it 'mixed available+unavailable candidates with no context/dimension failures → step 8 service_unavailable' do
      # One conclusively-fit candidate is unavailable; one is available.
      # Step 6's guard (all conclusively-fit are unavailable) does NOT fire
      # because one candidate is :available.
      # Step 7 (context_rejected) does NOT fire because neither candidate
      # has context_state or dimension_state == :rejected.
      # We fall through to step 8 — the service_unavailable catch-all.
      cands = [
        candidate(availability_state: :unavailable), # fit, unavailable
        candidate(availability_state: :available)    # fit, available
      ]
      r = diagnose(candidates: cands, statuses: [pub_status(state: :complete)])
      expect(r.kind).to eq(:service_unavailable)
      expect(r.http_status).to eq(503)
    end
  end

  describe 'Step 7 — context_rejected (catch-all)' do
    it 'all candidates context rejected → :context_rejected 400' do
      cands = [candidate(context_state: :rejected), candidate(context_state: :rejected)]
      r = diagnose(candidates: cands, statuses: [pub_status(state: :complete)])
      expect(r.kind).to eq(:context_rejected)
      expect(r.http_status).to eq(400)
    end

    it 'all candidates dimension rejected → :context_rejected 400' do
      cands = [candidate(dimension_state: :rejected), candidate(dimension_state: :rejected)]
      r = diagnose(candidates: cands, statuses: [pub_status(state: :complete)])
      expect(r.kind).to eq(:context_rejected)
      expect(r.http_status).to eq(400)
    end
  end

  # ---------------------------------------------------------------------------
  # Metadata checks
  # ---------------------------------------------------------------------------

  it 'carries inventory_generation from the EvaluationSet' do
    r = diagnose(gen: 42)
    expect(r.inventory_generation).to eq(42)
  end

  it 'returns a Rejection record' do
    expect(diagnose).to be_a(Legion::Extensions::Llm::Routing::Rejection)
  end

  it 'candidate_counts includes per-axis tallies' do
    cands = [candidate(policy_state: :denied)]
    r = diagnose(candidates: cands, statuses: [pub_status(state: :complete)])
    expect(r.candidate_counts[:policy_denied]).to eq(1)
  end
end
