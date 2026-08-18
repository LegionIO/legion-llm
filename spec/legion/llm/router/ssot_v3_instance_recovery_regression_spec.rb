# frozen_string_literal: true

require 'spec_helper'
require 'legion/llm/router/request_requirements'

# Original-incident regression: SSOT v3 instance-unavailable + probe-cleared recovery.
#
# The legacy HealthTracker circuit engine opened a circuit on failure and had no
# automatic recovery path — once open, instances were permanently excluded until a
# manual reset. This suite asserts the three guarantees of the replacement engine:
#
#   1. Ready instances publish → next_lane returns a Selection.
#   2. dispatch_instance_unavailable filters the instance; when ALL are unavailable,
#      next_lane returns a typed Rejection (retriable, 503/425/529) — not crash or nil.
#   3. Re-activating (probe success republishes the snapshot) clears the unavailable
#      state and makes next_lane select the instance again.
#   4. A transient provider outcome WITHOUT dispatch_instance_unavailable does NOT
#      poison the instance globally — repeated next_lane calls all return Selections.
RSpec.describe Legion::LLM::Router, '.next_lane instance-recovery regression', :ssot_v3 do
  def requirements(routing: {}, seed: 'ab' * 16, input: 10, output: 0)
    request = Legion::LLM::Inference::Request.build_for_test(
      routing_seed: seed, messages: [], routing: routing
    )
    Legion::LLM::Router::RequestRequirements.build(
      request: request, operation: :chat, required_capabilities: [],
      estimated_input_bound: input, required_output_tokens: output
    )
  end

  def next_lane(reqs = requirements, exclusions: [])
    described_class.next_lane(requirements: reqs, exclusions: exclusions, snapshot: snapshot)
  end

  def activate_peer(instance_id)
    activate(
      provider_family: 'vllm', instance_id: instance_id,
      drafts: [offering_draft(model: 'gemma4', supported: %i[chat], context: 200_000)]
    )
  end

  # Mark an instance unavailable using publisher_token_id from the supplied snapshot
  # (defaulting to the current registry snapshot). Capturing the snapshot before
  # multiple marks is safe: publisher_token_ids are stable across availability transitions.
  def mark_peer_unavailable(instance_id, from_snapshot = snapshot)
    key = instance_key(provider_family: 'vllm', instance_id: instance_id)
    token_id = from_snapshot.instance(instance_key: key).publisher_token_id
    inventory::Registry.dispatch_instance_unavailable(
      instance_key: key, publisher_token_id: token_id, reason: 'regression test: instance unavailable'
    )
  end

  # ─── 1. Selects a ready instance ─────────────────────────────────────────────

  it 'returns a Selection when at least one ready instance is published' do
    activate_peer('primary')
    activate_peer('secondary')
    result = next_lane
    expect(result).to be_a(Legion::Extensions::Llm::Routing::Selection)
    expect(result.provider_family).to eq(:vllm)
    expect(result.model).to eq('gemma4')
  end

  # ─── 2a. instance_unavailable is filtered; sibling is served ─────────────────

  it 'never returns the unavailable instance; routes to the healthy sibling instead' do
    activate_peer('primary')
    activate_peer('secondary')
    first = next_lane
    mark_peer_unavailable(first.instance_id.to_s)
    surviving = next_lane
    expect(surviving).to be_a(Legion::Extensions::Llm::Routing::Selection)
    expect(surviving.instance_id.to_s).not_to eq(first.instance_id.to_s)
  end

  # ─── 2b. All unavailable → typed Rejection, never a crash or nil ─────────────

  it 'returns a retriable Rejection when every instance is unavailable' do
    activate_peer('primary')
    activate_peer('secondary')
    # Capture snapshot once so both token_ids are read before either mark changes state.
    ready_snap = snapshot
    mark_peer_unavailable('primary', ready_snap)
    mark_peer_unavailable('secondary', ready_snap)
    result = next_lane
    expect(result).to be_a(Legion::Extensions::Llm::Routing::Rejection)
    expect(%i[service_unavailable too_early]).to include(result.kind)
    expect([503, 425, 529]).to include(result.http_status)
  end

  # ─── 3. Probe-cleared recovery (anti-regression core) ────────────────────────

  it 're-activating an unavailable instance makes next_lane select it again' do
    activate_peer('primary')
    mark_peer_unavailable('primary')
    # With only 'primary' published and it unavailable, expect a Rejection.
    expect(next_lane).to be_a(Legion::Extensions::Llm::Routing::Rejection)

    # Simulate probe success: provider readiness probe republishes the instance snapshot.
    # This is the exact recovery path that the old HealthTracker circuit engine lacked —
    # it opened circuits and never re-admitted them without a manual reset.
    activate_peer('primary')

    # After re-activation the instance must be selectable again.
    recovered = next_lane
    expect(recovered).to be_a(Legion::Extensions::Llm::Routing::Selection)
    expect(recovered.instance_id.to_s).to eq('primary')
    expect(recovered.model).to eq('gemma4')
  end

  # ─── 4. Transient stays request-local ────────────────────────────────────────

  it 'does not poison an instance globally when no dispatch_instance_unavailable is called' do
    activate_peer('primary')
    snap = snapshot
    results = 3.times.map do
      described_class.next_lane(requirements: requirements, exclusions: [], snapshot: snap)
    end
    expect(results).to all(be_a(Legion::Extensions::Llm::Routing::Selection))
  end
end
