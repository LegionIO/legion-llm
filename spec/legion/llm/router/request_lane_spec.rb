# frozen_string_literal: true

require 'spec_helper'
require 'legion/llm/router/request_requirements'

# Behavioral equivalents of the legacy #request_lane suite, migrated to the SSOT v3
# Router.next_lane selector stack.  request_lane is deleted; every surviving invariant
# is re-expressed here as next_lane -> Selection / Rejection.
#
# Deleted (no SSOT v3 equivalent):
#   - Bedrock region-prefix model normalization (request_lane-specific sieve logic)
#   - thinking: :forbid / :any  (not a routing filter in SSOT v3)
#   - half_open circuit state   (HealthTracker concept; replaced by instance availability)
#   - M1 indexed-read optimization  (internal implementation detail, Inventory.lanes_for)
#   - "treats missing context_window as unlimited"  (behavior changed: unknown context → not ready)
#   - Bucket selection via lane_weight patching  (internal weight mechanism has no SSOT v3 path)
RSpec.describe Legion::LLM::Router, '.next_lane (migrated from #request_lane)', :ssot_v3 do
  # Build a RequestRequirements from a lightweight test request. All params
  # except seed forward to RequestRequirements.build so callers can override any axis.
  def reqs(operation: :chat, capabilities: [], routing: {}, seed: 'ab' * 16,
           input: 0, output: 0, tier_constraint: nil)
    request = Legion::LLM::Inference::Request.build_for_test(
      routing_seed: seed, messages: [], routing: routing
    )
    Legion::LLM::Router::RequestRequirements.build(
      request:                request,
      operation:              operation,
      required_capabilities:  capabilities,
      estimated_input_bound:  input,
      required_output_tokens: output,
      tier_constraint:        tier_constraint
    )
  end

  # Invoke the selector, taking a fresh snapshot each time so callers do not need to
  # capture it explicitly unless they need snapshot-stable multi-call tests.
  def nl(requirements = reqs, exclusions: [])
    described_class.next_lane(requirements: requirements, exclusions: exclusions, snapshot: snapshot)
  end

  # Build an attempt_target Exclusion for the given (provider, instance_id, model) triple.
  def attempt_exclusion(provider:, instance_id:, model:)
    atk = Legion::Extensions::Llm::Routing::AttemptTargetKey.new(
      provider_family: provider.to_sym,
      instance_id:     instance_id.to_s,
      model:           model.to_s
    )
    Legion::Extensions::Llm::Routing::Exclusion.new(
      target_kind: :attempt_target, target: atk,
      reason: 'attempt_consumed', evidence: {}, lifetime: :request
    )
  end

  # Activate a single instance with a specific context window. write_test_lane always
  # uses context: 200_000; use this helper when a test needs a different value.
  def activate_with_context(provider:, instance_id:, model:, context:, tier: :local)
    SsotV3SnapshotFactory.activate(
      provider_family: provider.to_s,
      instance_id:     instance_id.to_s,
      callable:        SsotStubCallable.new(content: 'ok', input_tokens: 10,
                                            output_tokens: 5, tool_calls: []),
      drafts:          [SsotV3SnapshotFactory.offering_draft(
        model:     model.to_s,
        tier:      tier,
        supported: %i[chat stream_chat count_tokens],
        context:   context
      )]
    )
  end

  # ─── Operation (type) filter ───────────────────────────────────────────────

  describe 'operation filter' do
    it 'returns a Rejection when no offering supports the requested operation' do
      write_test_lane(provider: :vllm, model: 'gemma-12b', type: :inference)
      expect(nl(reqs(operation: :embed))).to be_a(Legion::Extensions::Llm::Routing::Rejection)
    end

    it 'returns a Selection when an offering supports the requested operation' do
      write_test_lane(provider: :vllm, model: 'gemma-12b', type: :inference)
      result = nl(reqs(operation: :chat))
      expect(result).to be_a(Legion::Extensions::Llm::Routing::Selection)
      expect(result.provider_family).to eq(:vllm)
    end
  end

  # ─── Tier constraint ───────────────────────────────────────────────────────

  describe 'tier constraint (replaces request_lane tiers: allow-set)' do
    it 'selects the matching-tier offering and excludes the other tier' do
      write_test_lane(provider: :vllm, model: 'gemma-12b', tier: :local)
      write_test_lane(provider: :bedrock, instance: :b, model: 'claude-sonnet-4-6', tier: :cloud)
      result = nl(reqs(tier_constraint: :local))
      expect(result).to be_a(Legion::Extensions::Llm::Routing::Selection)
      expect(result.provider_family).to eq(:vllm)
    end

    it 'returns a Rejection when the tier constraint excludes all available offerings' do
      write_test_lane(provider: :vllm, model: 'gemma-12b', tier: :local)
      expect(nl(reqs(tier_constraint: :cloud))).to be_a(Legion::Extensions::Llm::Routing::Rejection)
    end
  end

  # ─── Provider pin ──────────────────────────────────────────────────────────

  describe 'provider pin (replaces request_lane providers: allow-set)' do
    it 'selects only the pinned provider' do
      write_test_lane(provider: :vllm, model: 'gemma-12b', tier: :local)
      write_test_lane(provider: :bedrock, instance: :b, model: 'claude-sonnet-4-6', tier: :cloud)
      result = nl(reqs(routing: { provider: 'bedrock' }))
      expect(result).to be_a(Legion::Extensions::Llm::Routing::Selection)
      expect(result.provider_family).to eq(:bedrock)
    end

    it 'returns a Rejection when the pinned provider has no offerings in the registry' do
      write_test_lane(provider: :vllm, model: 'gemma-12b', tier: :local)
      expect(nl(reqs(routing: { provider: 'bedrock' }))).to be_a(Legion::Extensions::Llm::Routing::Rejection)
    end
  end

  # ─── Instance pin ──────────────────────────────────────────────────────────

  describe 'instance pin (replaces request_lane instances: allow-set)' do
    it 'selects only the pinned instance' do
      write_test_lane(provider: :vllm, instance: :apollo, model: 'gemma-12b')
      write_test_lane(provider: :vllm, instance: :hermes, model: 'gemma-12b')
      result = nl(reqs(routing: { instance: 'apollo' }))
      expect(result).to be_a(Legion::Extensions::Llm::Routing::Selection)
      expect(result.instance_id.to_s).to eq('apollo')
    end
  end

  # ─── Model pin ────────────────────────────────────────────────────────────

  describe 'model pin (replaces request_lane models: allow-set)' do
    it 'selects only the pinned model' do
      write_test_lane(provider: :vllm, model: 'gemma-12b')
      write_test_lane(provider: :vllm, instance: :b, model: 'llama3-8b')
      result = nl(reqs(routing: { model: 'llama3-8b' }))
      expect(result).to be_a(Legion::Extensions::Llm::Routing::Selection)
      expect(result.model).to eq('llama3-8b')
    end
  end

  # ─── No constraints = permissive ─────────────────────────────────────────

  describe 'unconstrained request' do
    it 'selects any eligible lane when no pins or constraints are set (empty lists are all-pass)' do
      write_test_lane(provider: :vllm, model: 'gemma-12b')
      expect(nl).to be_a(Legion::Extensions::Llm::Routing::Selection)
    end
  end

  # ─── Required capabilities ────────────────────────────────────────────────

  describe 'required capabilities' do
    it 'selects the lane that is a superset of the requested capabilities' do
      write_test_lane(provider: :vllm, model: 'gemma-12b', capabilities: [:streaming])
      write_test_lane(provider: :anthropic, instance: :a, model: 'claude-sonnet-4-6',
                      capabilities: %i[tools streaming])
      result = nl(reqs(capabilities: [:tools]))
      expect(result).to be_a(Legion::Extensions::Llm::Routing::Selection)
      expect(result.provider_family).to eq(:anthropic)
    end

    it 'returns a Rejection when no offering declares the required capability' do
      write_test_lane(provider: :vllm, model: 'gemma-12b', capabilities: [:streaming])
      expect(nl(reqs(capabilities: [:tools]))).to be_a(Legion::Extensions::Llm::Routing::Rejection)
    end

    # Capability normalization: :function_calling and :tool_use are both aliases for
    # :tools.  RequestRequirements normalizes via Capabilities.normalize so requesting
    # an alias selects a lane that declares the canonical form.
    it 'capability normalization — requesting :function_calling selects a :tools lane (alias collapses)' do
      write_test_lane(provider: :openai, model: 'gpt-5.4', capabilities: [:tools])
      result = nl(reqs(capabilities: [:function_calling]))
      expect(result).to be_a(Legion::Extensions::Llm::Routing::Selection)
      expect(result.provider_family).to eq(:openai)
    end

    it 'capability normalization — requesting :tool_use selects a :tools lane (alias collapses)' do
      write_test_lane(provider: :vllm, model: 'gemma-12b', capabilities: [:tools])
      result = nl(reqs(capabilities: [:tool_use]))
      expect(result).to be_a(Legion::Extensions::Llm::Routing::Selection)
    end

    it 'capability normalization — an offering declaring both :function_calling and :tools is selected via :tool_use' do
      SsotV3SnapshotFactory.activate(
        provider_family: 'anthropic',
        instance_id:     'cloud1',
        callable:        SsotStubCallable.new(content: 'ok', input_tokens: 10,
                                              output_tokens: 5, tool_calls: []),
        drafts:          [SsotV3SnapshotFactory.offering_draft(
          model:        'claude-sonnet-4-6',
          tier:         :frontier,
          supported:    %i[chat stream_chat count_tokens],
          capabilities: { function_calling: :supported, tools: :supported }
        )]
      )
      result = nl(reqs(capabilities: [:tool_use]))
      expect(result).to be_a(Legion::Extensions::Llm::Routing::Selection)
    end

    it 'filters by thinking: :require — only a thinking-capable lane is selected' do
      write_test_lane(provider: :vllm, model: 'gemma-12b', capabilities: [:streaming])
      write_test_lane(provider: :anthropic, instance: :a, model: 'claude-sonnet-4-6',
                      capabilities: %i[streaming thinking])
      result = nl(reqs(capabilities: [:thinking]))
      expect(result).to be_a(Legion::Extensions::Llm::Routing::Selection)
      expect(result.provider_family).to eq(:anthropic)
    end
  end

  # ─── Context budget filter ────────────────────────────────────────────────

  describe 'context budget filter (replaces request_lane estimated_context: param)' do
    it 'selects the lane whose context window is large enough for the request' do
      activate_with_context(provider: :vllm, instance_id: 'small', model: 'small-model',
                             context: 8_000, tier: :local)
      write_test_lane(provider: :anthropic, model: 'claude-sonnet-4-6', tier: :frontier) # 200_000
      result = nl(reqs(input: 50_000))
      expect(result).to be_a(Legion::Extensions::Llm::Routing::Selection)
      expect(result.provider_family).to eq(:anthropic)
    end

    it 'returns a Rejection when all offerings have insufficient context windows' do
      activate_with_context(provider: :vllm, instance_id: 'small', model: 'small-model',
                             context: 8_000, tier: :local)
      expect(nl(reqs(input: 50_000))).to be_a(Legion::Extensions::Llm::Routing::Rejection)
    end
  end

  # ─── Exclusions (tried-lanes analog) ─────────────────────────────────────

  describe 'exclusions (replaces request_lane tried_lanes: param)' do
    it 'excludes the consumed instance and selects the alternative' do
      write_test_lane(provider: :vllm, instance: :a, model: 'gemma-12b')
      write_test_lane(provider: :vllm, instance: :b, model: 'gemma-12b')
      r = reqs
      first = nl(r)
      expect(first).to be_a(Legion::Extensions::Llm::Routing::Selection)
      excl = attempt_exclusion(provider: :vllm, instance_id: first.instance_id, model: first.model)
      second = nl(r, exclusions: [excl])
      expect(second).to be_a(Legion::Extensions::Llm::Routing::Selection)
      expect(second.instance_id.to_s).not_to eq(first.instance_id.to_s)
    end

    it 'falls back when the first selection is excluded — alternative tiers / instances are served' do
      write_test_lane(provider: :vllm, instance: :primary, model: 'gemma-12b', tier: :local)
      write_test_lane(provider: :bedrock, instance: :secondary, model: 'claude-sonnet-4-6', tier: :cloud)
      r = reqs
      first = nl(r)
      excl = attempt_exclusion(provider: first.provider_family, instance_id: first.instance_id,
                                model: first.model)
      second = nl(r, exclusions: [excl])
      expect(second).to be_a(Legion::Extensions::Llm::Routing::Selection)
      expect(second.instance_id.to_s).not_to eq(first.instance_id.to_s)
    end

    it 'returns a Rejection when all eligible instances are excluded (single-lane inventory)' do
      write_test_lane(provider: :vllm, model: 'gemma-12b')
      r = reqs
      first = nl(r)
      excl = attempt_exclusion(provider: :vllm, instance_id: first.instance_id, model: first.model)
      expect(nl(r, exclusions: [excl])).to be_a(Legion::Extensions::Llm::Routing::Rejection)
    end

    it 'returns a Rejection when all instances are excluded (two-lane inventory, both consumed)' do
      write_test_lane(provider: :vllm, instance: :a, model: 'gemma-12b')
      write_test_lane(provider: :vllm, instance: :b, model: 'gemma-12b')
      snap = snapshot
      r    = reqs
      first = described_class.next_lane(requirements: r, exclusions: [], snapshot: snap)
      excl_a = attempt_exclusion(provider: :vllm, instance_id: first.instance_id, model: first.model)
      second = described_class.next_lane(requirements: r, exclusions: [excl_a], snapshot: snap)
      expect(second).to be_a(Legion::Extensions::Llm::Routing::Selection)
      excl_b = attempt_exclusion(provider: :vllm, instance_id: second.instance_id, model: second.model)
      result = described_class.next_lane(requirements: r, exclusions: [excl_a, excl_b], snapshot: snap)
      expect(result).to be_a(Legion::Extensions::Llm::Routing::Rejection)
    end
  end

  # ─── Instance unavailability (replaces lane_weight ≤ 0 / circuit-open) ────

  describe 'instance unavailability (circuit-open analog)' do
    it 'returns a Rejection when the only instance is marked unavailable' do
      token = SsotV3SnapshotFactory.activate(
        provider_family: 'vllm',
        instance_id:     'primary',
        callable:        SsotStubCallable.new(content: 'ok', input_tokens: 10,
                                              output_tokens: 5, tool_calls: []),
        drafts:          [SsotV3SnapshotFactory.offering_draft(
          model:     'gemma-12b',
          tier:      :local,
          supported: %i[chat stream_chat count_tokens]
        )]
      )
      SsotV3SnapshotFactory.mark_unavailable(
        provider_family:    'vllm',
        instance_id:        'primary',
        publisher_token_id: token.publisher_token_id
      )
      expect(nl).to be_a(Legion::Extensions::Llm::Routing::Rejection)
    end

    it 'never bypasses instance unavailability — a disabled instance stays disabled (denied-lane analog)' do
      token = SsotV3SnapshotFactory.activate(
        provider_family: 'openai',
        instance_id:     'primary',
        callable:        SsotStubCallable.new(content: 'ok', input_tokens: 10,
                                              output_tokens: 5, tool_calls: []),
        drafts:          [SsotV3SnapshotFactory.offering_draft(
          model:     'gpt-5.5',
          tier:      :frontier,
          supported: %i[chat stream_chat count_tokens]
        )]
      )
      SsotV3SnapshotFactory.mark_unavailable(
        provider_family:    'openai',
        instance_id:        'primary',
        publisher_token_id: token.publisher_token_id
      )
      expect(nl).to be_a(Legion::Extensions::Llm::Routing::Rejection)
    end
  end

  # ─── Tier constraint isolates external tiers (privacy-strict analog) ───────

  describe 'tier constraint isolates external tiers (replaces privacy: :strict)' do
    it 'selects only the local-tier instance when tier_constraint is :local' do
      write_test_lane(provider: :vllm,      model: 'gemma-12b',          tier: :local)
      write_test_lane(provider: :bedrock,   instance: :b, model: 'claude-sonnet-4-6', tier: :cloud)
      write_test_lane(provider: :anthropic, instance: :c, model: 'claude-sonnet-4-6', tier: :frontier)
      result = nl(reqs(tier_constraint: :local))
      expect(result).to be_a(Legion::Extensions::Llm::Routing::Selection)
      expect(result.provider_family).to eq(:vllm)
    end

    it 'returns a Rejection when tier_constraint excludes all available offerings' do
      write_test_lane(provider: :bedrock, model: 'claude-sonnet-4-6', tier: :cloud)
      expect(nl(reqs(tier_constraint: :local))).to be_a(Legion::Extensions::Llm::Routing::Rejection)
    end
  end

  # ─── No hail-mary (G24) ────────────────────────────────────────────────────

  describe 'no hail-mary (G24) — no implicit default bypass' do
    it 'returns a Rejection when provider pin excludes all lanes — even if a default provider is configured' do
      Legion::Settings.loader.settings[:llm][:default_provider] = :openai
      Legion::Settings.loader.settings[:llm][:default_model]    = 'gpt-5.5'
      write_test_lane(provider: :openai, model: 'gpt-5.5', tier: :frontier)
      expect(nl(reqs(routing: { provider: 'bedrock' }))).to be_a(Legion::Extensions::Llm::Routing::Rejection)
    end

    it 'configured default lane is not a hail-mary bypass — filters still apply' do
      Legion::Settings.loader.settings[:llm][:default_provider] = :anthropic
      Legion::Settings.loader.settings[:llm][:default_model]    = 'claude-sonnet-4-6'
      write_test_lane(provider: :anthropic, model: 'claude-sonnet-4-6', tier: :frontier)
      expect(nl(reqs(routing: { provider: 'bedrock' }))).to be_a(Legion::Extensions::Llm::Routing::Rejection)
    end

    it 'settings key llm.routing.last_resort_default has no effect (G24)' do
      Legion::Settings.loader.settings[:llm][:routing] ||= {}
      Legion::Settings.loader.settings[:llm][:routing][:last_resort_default] = 'gpt-5.5'
      write_test_lane(provider: :openai, model: 'gpt-5.5', tier: :frontier)
      expect(nl(reqs(routing: { provider: 'bedrock' }))).to be_a(Legion::Extensions::Llm::Routing::Rejection)
    end
  end

  # ─── Exhaustion ────────────────────────────────────────────────────────────

  describe 'exhaustion' do
    it 'returns a Rejection when the inventory is empty' do
      expect(nl).to be_a(Legion::Extensions::Llm::Routing::Rejection)
    end

    it 'returns a Rejection when all lanes are filtered out by hard filters' do
      write_test_lane(provider: :vllm, model: 'gemma-12b', tier: :local)
      expect(nl(reqs(tier_constraint: :cloud))).to be_a(Legion::Extensions::Llm::Routing::Rejection)
    end
  end

  # ─── Determinism (G25) ────────────────────────────────────────────────────

  describe 'determinism (G25)' do
    it 'same seed + same catalog + same snapshot = same selection every time' do
      3.times { |i| write_test_lane(provider: :vllm, instance: :"i#{i}", model: 'gemma-12b') }
      snap = snapshot
      seed = 'cd' * 16
      a = described_class.next_lane(requirements: reqs(seed: seed), exclusions: [], snapshot: snap)
      b = described_class.next_lane(requirements: reqs(seed: seed), exclusions: [], snapshot: snap)
      expect(a).to be_a(Legion::Extensions::Llm::Routing::Selection)
      expect(a.lane_id).to eq(b.lane_id)
    end

    it 'different seeds with the same catalog distribute selection across instances' do
      3.times { |i| write_test_lane(provider: :vllm, instance: :"i#{i}", model: 'gemma-12b') }
      snap    = snapshot
      results = 30.times.map do |i|
        seed = i.to_s(16).rjust(2, '0') * 16
        described_class.next_lane(requirements: reqs(seed: seed), exclusions: [], snapshot: snap)
      end
      expect(results).to all(be_a(Legion::Extensions::Llm::Routing::Selection))
      expect(results.map(&:instance_id).uniq.size).to be > 1
    end
  end
end
