# frozen_string_literal: true

require 'spec_helper'
require 'legion/llm/router_new'

# Instance-recovery regression re-encoded against the NEW Router CLASS (SSOT v4).
#
# The legacy HealthTracker circuit engine opened a circuit on failure and had no
# automatic recovery path — once open, instances were permanently excluded until a
# manual reset. This suite asserts the four guarantees of the replacement engine
# using the per-request Router instance API:
#
#   1. Ready instances publish → next_lane returns a Selection.
#   2. dispatch_instance_unavailable filters the instance; when ALL are unavailable,
#      next_lane returns a typed Rejection (retriable, 503/425/529) — not crash or nil.
#   3. Re-activating (probe success republishes the snapshot) clears the unavailable
#      state and makes next_lane select the instance again.
#   4. A transient provider outcome WITHOUT dispatch_instance_unavailable does NOT
#      poison the instance globally — repeated next_lane calls all return Selections.
RSpec.describe Legion::LLM::Router, 'instance-recovery regression (class API)', :ssot_v3 do
  # ---------------------------------------------------------------------------
  # Helpers — mirror router_new_spec patterns exactly
  # ---------------------------------------------------------------------------

  def build_request(seed: 'ab' * 16, messages: [], routing: {})
    Legion::LLM::Inference::Request.build_for_test(
      routing_seed: seed, messages: messages, routing: routing
    )
  end

  def build_router(request: nil, operation: :chat, body_model: nil, **request_kwargs)
    req = request || build_request(**request_kwargs)
    Legion::LLM::Router.new(request: req, operation: operation, body_model: body_model)
  end

  def activate_peer(instance_id)
    activate_lane(
      provider: :vllm, instance_id: instance_id, model: 'gemma4',
      supported: %i[chat stream_chat count_tokens],
      capabilities: { streaming: :supported, tools: :supported },
      context: 200_000, max_output: 16_384
    )
  end

  def activate_lane(provider:, instance_id:, model:, tier: :local,
                    supported: %i[chat stream_chat count_tokens],
                    capabilities: { streaming: :supported, tools: :supported },
                    context: 200_000, max_output: 16_384)
    SsotV3SnapshotFactory.activate(
      provider_family: provider.to_s,
      instance_id:     instance_id,
      callable:        SsotV3SnapshotFactory::FactoryCallable.new,
      drafts:          [SsotV3SnapshotFactory.offering_draft(
        model: model, tier: tier, supported: supported,
        capabilities: capabilities, context: context, max_output: max_output
      )]
    )
  end

  # Mark an instance unavailable via the real Registry dispatch path.
  # Looks up publisher_token_id from the current snapshot (stable across transitions)
  # unless explicitly provided. Mirrors the source spec's snapshot-based lookup.
  def mark_peer_unavailable(instance_id, publisher_token_id: nil)
    token_id = publisher_token_id || begin
      key = SsotV3SnapshotFactory.instance_key(provider_family: 'vllm', instance_id: instance_id)
      SsotV3SnapshotFactory.snapshot.instance(instance_key: key).publisher_token_id
    end
    SsotV3SnapshotFactory.mark_unavailable(
      provider_family: 'vllm', instance_id: instance_id,
      publisher_token_id: token_id
    )
  end

  before do
    Legion::Settings[:llm][:router] ||= Legion::LLM::Settings::Router.defaults
    Legion::Settings[:extensions][:llm] ||= {}
  end

  # ─── 1. Selects a ready instance ─────────────────────────────────────────────

  it 'returns a Selection when at least one ready instance is published' do
    activate_peer('primary')
    activate_peer('secondary')
    router = build_router
    result = router.next_lane
    expect(result).to be_a(Legion::Extensions::Llm::Routing::Selection)
    expect(result.provider_family).to eq(:vllm)
    expect(result.model).to eq('gemma4')
  end

  # ─── 2a. instance_unavailable is filtered; sibling is served ─────────────────

  it 'never returns the unavailable instance; routes to the healthy sibling instead' do
    activate_peer('primary')
    activate_peer('secondary')

    # First selection to identify which instance gets picked
    router = build_router
    first = router.next_lane
    expect(first).to be_a(Legion::Extensions::Llm::Routing::Selection)

    # Mark the selected instance unavailable (token looked up from live snapshot)
    mark_peer_unavailable(first.instance_id.to_s)

    # A fresh router (new request) must route around the downed instance
    router2 = build_router
    surviving = router2.next_lane
    expect(surviving).to be_a(Legion::Extensions::Llm::Routing::Selection)
    expect(surviving.instance_id.to_s).not_to eq(first.instance_id.to_s)
  end

  # ─── 2b. All unavailable → typed Rejection, never a crash or nil ─────────────

  it 'returns a retriable Rejection when every instance is unavailable' do
    activate_peer('primary')
    activate_peer('secondary')

    # Mark both unavailable (snapshot lookup resolves token_ids for both before either
    # mark mutates state — publisher_token_ids are stable across availability transitions)
    mark_peer_unavailable('primary')
    mark_peer_unavailable('secondary')

    router = build_router
    result = router.next_lane
    expect(result).to be_a(Legion::Extensions::Llm::Routing::Rejection)
    expect(%i[service_unavailable too_early]).to include(result.kind)
    expect([503, 425, 529]).to include(result.http_status)
  end

  # ─── 3. Probe-cleared recovery (anti-regression core) ────────────────────────

  it 're-activating an unavailable instance makes next_lane select it again' do
    activate_peer('primary')
    mark_peer_unavailable('primary')

    # With only 'primary' published and it unavailable, expect a Rejection.
    router = build_router
    expect(router.next_lane).to be_a(Legion::Extensions::Llm::Routing::Rejection)

    # Simulate probe success: provider readiness probe republishes the instance snapshot.
    # This is the exact recovery path that the old HealthTracker circuit engine lacked —
    # it opened circuits and never re-admitted them without a manual reset.
    activate_peer('primary')

    # After re-activation the instance must be selectable again.
    router2 = build_router
    recovered = router2.next_lane
    expect(recovered).to be_a(Legion::Extensions::Llm::Routing::Selection)
    expect(recovered.instance_id.to_s).to eq('primary')
    expect(recovered.model).to eq('gemma4')
  end

  # ─── 4. Transient stays request-local ────────────────────────────────────────

  it 'does not poison an instance globally when no dispatch_instance_unavailable is called' do
    activate_peer('primary')

    # Multiple independent router instances (simulating separate requests) all succeed.
    # No dispatch_instance_unavailable is ever called — the instance stays globally healthy.
    results = 3.times.map do
      router = build_router
      router.next_lane
    end
    expect(results).to all(be_a(Legion::Extensions::Llm::Routing::Selection))
  end
end
