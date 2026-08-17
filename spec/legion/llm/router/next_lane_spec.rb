# frozen_string_literal: true

require 'spec_helper'
require 'legion/llm/router/request_requirements'

# Aggregate behavior spec for Router.next_lane (§12) — the full evaluator → ranker
# → diagnostics stack against real Phase 1 snapshots from the factory.
RSpec.describe Legion::LLM::Router, '.next_lane', :ssot_v3 do
  def requirements(operation: :chat, capabilities: [], routing: {}, seed: 'ab' * 16,
                   input: 10, output: 0, **over)
    request = Legion::LLM::Inference::Request.build_for_test(
      routing_seed: seed, messages: [], routing: routing
    )
    Legion::LLM::Router::RequestRequirements.build(
      request: request, operation: operation, required_capabilities: capabilities,
      estimated_input_bound: input, required_output_tokens: output, **over
    )
  end

  def next_lane(reqs = requirements, exclusions: [])
    described_class.next_lane(requirements: reqs, exclusions: exclusions, snapshot: snapshot)
  end

  it 'returns a Selection for an eligible unconstrained request' do
    activate(provider_family: 'vllm', instance_id: 'h200',
             drafts: [offering_draft(model: 'gemma4', supported: %i[chat], context: 200_000)])
    sel = next_lane
    expect(sel).to be_a(Legion::Extensions::Llm::Routing::Selection)
    expect(sel.model).to eq('gemma4')
    expect(sel.provider_family).to eq(:vllm)
  end

  it 'returns a too_early Rejection on a cold (empty) registry' do
    rej = next_lane
    expect(rej).to be_a(Legion::Extensions::Llm::Routing::Rejection)
    expect(rej.kind).to eq(:too_early)
  end

  it 'matches an explicit model pin across every provider/instance (N x N, no inferred provider)' do
    activate(provider_family: 'vllm', instance_id: 'h200',
             drafts: [offering_draft(model: 'gemma4', supported: %i[chat], context: 200_000)])
    activate(provider_family: 'ollama', instance_id: 'local1',
             drafts: [offering_draft(model: 'gemma4', supported: %i[chat], context: 200_000)])
    sel = next_lane(requirements(routing: { model: 'gemma4' }))
    expect(sel.model).to eq('gemma4')
    expect(%i[vllm ollama]).to include(sel.provider_family)
  end

  it 'is deterministic for a fixed seed + generation' do
    activate(provider_family: 'vllm', instance_id: 'h200',
             drafts: [offering_draft(model: 'gemma4', supported: %i[chat], context: 200_000)])
    activate(provider_family: 'vllm', instance_id: 'helios1',
             drafts: [offering_draft(model: 'gemma4', supported: %i[chat], context: 200_000)])
    snap = snapshot
    a = described_class.next_lane(requirements: requirements(seed: 'cd' * 16), exclusions: [], snapshot: snap)
    b = described_class.next_lane(requirements: requirements(seed: 'cd' * 16), exclusions: [], snapshot: snap)
    expect(a.lane_id).to eq(b.lane_id)
  end

  it 'excludes a consumed attempt_target and selects a different eligible target' do
    activate(provider_family: 'vllm', instance_id: 'h200',
             drafts: [offering_draft(model: 'gemma4', supported: %i[chat], context: 200_000)])
    activate(provider_family: 'vllm', instance_id: 'helios1',
             drafts: [offering_draft(model: 'gemma4', supported: %i[chat], context: 200_000)])
    reqs = requirements(routing: { model: 'gemma4' })
    first = next_lane(reqs)
    exclusion = Legion::Extensions::Llm::Routing::Exclusion.new(
      target_kind: :attempt_target, target: first.attempt_target_key,
      reason: 'attempt_consumed', evidence: {}, lifetime: :request
    )
    second = next_lane(reqs, exclusions: [exclusion])
    expect(second).to be_a(Legion::Extensions::Llm::Routing::Selection)
    expect(second.attempt_target_key).not_to eq(first.attempt_target_key)
  end

  it 'validates exclusions and snapshot types' do
    expect { described_class.next_lane(requirements: requirements, exclusions: [:bad], snapshot: snapshot) }
      .to raise_error(ArgumentError)
    expect { described_class.next_lane(requirements: requirements, exclusions: [], snapshot: :notsnap) }
      .to raise_error(ArgumentError)
  end

  # ------------------------------------------------------------------- #
  # Fail-forward (2026-08-16): typed failures, no unbounded 529          #
  # ------------------------------------------------------------------- #

  describe 'fail-forward: a settled :unknown required capability' do
    before { Legion::LLM::Router::SettingsState.reset! }

    it 'is a terminal typed 400 (invalid_request), never an unbounded too_early/529' do
      # A complete publication scope whose provider cannot attest :thinking
      # (evidence :unknown, config contract-forbidden as evidence) and no
      # operator enable_thinking override.
      activate(
        provider_family: 'vllm', instance_id: 'apollo',
        drafts: [offering_draft(
          model: 'gemma4', supported: %i[chat stream_chat], context: 200_000,
          capabilities: { streaming: :supported, tools: :supported }
          # thinking: absent → :unknown
        )]
      )
      rej = next_lane(requirements(capabilities: %i[thinking]))

      expect(rej).to be_a(Legion::Extensions::Llm::Routing::Rejection)
      expect(rej.kind).to eq(:invalid_request)
      expect(rej.http_status).to eq(400)
      expect(rej.kind).not_to eq(:too_early)
    end

    it 'routes when the operator attests the capability via the config-name enable_* override' do
      activate(
        provider_family: 'vllm', instance_id: 'apollo',
        drafts: [offering_draft(
          model: 'gemma4', supported: %i[chat stream_chat], context: 200_000,
          capabilities: { streaming: :supported, tools: :supported }
          # thinking: absent → :unknown
        )]
      )
      # The frozen employee-config shape: per-instance tuning keyed by the
      # config NAME, with an enable_* override.
      Legion::Settings[:extensions][:llm][:vllm] = {
        instances: { 'apollo' => { enable_thinking: true, weight: 100 } }
      }

      sel = next_lane(requirements(capabilities: %i[thinking]))
      expect(sel).to be_a(Legion::Extensions::Llm::Routing::Selection)
      expect(sel.instance_id).to eq('apollo')
    end

    it 'reports a tripped instance as 503, not 529, when another candidate has unknown evidence' do
      token = activate(
        provider_family: 'vllm', instance_id: 'apollo',
        drafts: [offering_draft(
          model: 'gemma4', supported: %i[chat stream_chat], context: 200_000,
          capabilities: { streaming: :supported, tools: :supported }
        )]
      )
      activate(
        provider_family: 'ollama', instance_id: 'apollo-embed',
        drafts: [offering_draft(
          model: 'gemma4', supported: %i[chat stream_chat], context: 200_000,
          capabilities: { streaming: :supported, tools: :supported }
          # thinking: absent → :unknown
        )]
      )
      mark_unavailable(
        provider_family:    'vllm',
        instance_id:        'apollo',
        publisher_token_id: token.publisher_token_id
      )

      rej = next_lane(requirements(capabilities: %i[thinking]))
      expect(rej).to be_a(Legion::Extensions::Llm::Routing::Rejection)
      expect(rej.kind).to eq(:service_unavailable)
      expect(rej.http_status).to eq(503)
    end

    it 'routes a tools+thinking request to the sibling provider that CAN attest both' do
      activate(
        provider_family: 'vllm', instance_id: 'apollo',
        drafts: [offering_draft(
          model: 'gemma4', supported: %i[chat stream_chat], context: 200_000,
          capabilities: { streaming: :supported, tools: :supported }
          # thinking: absent → :unknown (no misroute here — not ready)
        )]
      )
      activate(
        provider_family: 'bedrock', instance_id: 'primary',
        drafts: [offering_draft(
          model: 'gemma4', supported: %i[chat stream_chat], context: 200_000, tier: :cloud,
          capabilities: { streaming: :supported, tools: :supported, thinking: :supported }
        )]
      )

      sel = next_lane(requirements(capabilities: %i[tools thinking]))
      expect(sel).to be_a(Legion::Extensions::Llm::Routing::Selection)
      expect(sel.provider_family).to eq(:bedrock)
    end
  end
end
