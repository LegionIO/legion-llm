# frozen_string_literal: true

require 'spec_helper'

# Task 0 (Phase 2 SSOT v3): verify the installed released lex-llm >= 0.7.0
# contract that Phase 2 consumes verbatim. This spec contains NO local fake
# implementation of any Phase 1 type; it reflects only against the installed
# gem and fails immediately when Phase 1 drifts.
#
# Contract-trace finding: both plan docs write
# `Legion::Extensions::Llm::Inventory::InstanceKey`, but the released 0.7.0 gem
# canonically defines it at `Inventory::Identity::InstanceKey` (used internally
# by records.rb/snapshot.rb/registry.rb). Phase 2 consumes the real released
# path. This spec asserts that real path.
RSpec.describe 'Phase 1 lex-llm SSOT v3 contract' do
  let(:inventory) { Legion::Extensions::Llm::Inventory }
  let(:routing) { Legion::Extensions::Llm::Routing }
  let(:taxonomies) { Legion::Extensions::Llm::Taxonomies }

  it 'installs lex-llm >= 0.7.0' do
    version = Gem::Version.new(Legion::Extensions::Llm::VERSION)
    expect(version).to be >= Gem::Version.new('0.7.0')
  end

  describe 'taxonomy members' do
    it 'exposes the exact OPERATIONS enum' do
      expect(taxonomies::OPERATIONS).to eq(
        %i[chat stream_chat embed image transcribe translate speak moderate count_tokens]
      )
    end

    it 'exposes the normalized provider outcomes' do
      expect(taxonomies::PROVIDER_OUTCOMES).to include(
        :success, :instance_unavailable, :overloaded, :model_not_ready, :rate_limited,
        :authentication, :authorization, :billing, :policy, :invalid_request, :model_missing,
        :context_rejected, :safety_refusal, :malformed_output, :tool_failure, :timeout,
        :connection_failure, :provider_error, :cancelled, :client_disconnect
      )
    end

    it 'exposes the routing rejection kinds' do
      expect(taxonomies::REJECTION_KINDS).to eq(
        %i[invalid_routing_context invalid_request policy_denied failed_dependency
           too_early service_unavailable context_rejected attempts_exhausted stale_selection]
      )
    end

    it 'exposes the body-model hint dispositions' do
      expect(taxonomies::BODY_MODEL_HINT_DISPOSITIONS).to eq(
        %i[absent auto superseded_by_explicit_model ignored_disabled
           ignored_not_whitelisted ignored_blacklisted honored]
      )
    end
  end

  describe 'identity and routing records' do
    it 'constructs Inventory::Identity::InstanceKey with (provider_family:, instance_id:)' do
      key = inventory::Identity::InstanceKey.new(provider_family: 'vllm', instance_id: 'h200')
      expect(key.provider_family).to eq(:vllm)
      expect(key.instance_id).to eq('h200')
    end

    it 'reproduces the binding offering_id and lane_id identity vectors' do
      key = inventory::Identity::InstanceKey.new(provider_family: 'vllm', instance_id: 'h200')
      offering_id = inventory::Identity.offering_id(instance_key: key, provider_native_key: 'gemma4')
      lane_id = inventory::Identity.lane_id(
        instance_key: key, operation: :chat, model: 'gemma4', offering_id: offering_id
      )
      expect(offering_id).to eq(
        'off:v1:c966772d7f8f428c24a77be96f94e111ba1052bf093098f0413b562c1059dcd1'
      )
      expect(lane_id).to eq(
        'lane:v1:430444bb58975ab56329c7c3a6c483a1b9cb49d1c089a56f3c93c6aa27d5f9b3'
      )
    end

    it 'constructs AttemptTargetKey with (provider_family:, instance_id:, model:)' do
      atk = routing::AttemptTargetKey.new(provider_family: 'vllm', instance_id: 'h200', model: 'gemma4')
      expect(atk.provider_family).to eq(:vllm)
      expect(atk.instance_id).to eq('h200')
      expect(atk.model).to eq('gemma4')
    end

    it 'keeps two instances of the same provider+model as distinct attempt identities' do
      a = routing::AttemptTargetKey.new(provider_family: 'vllm', instance_id: 'h200', model: 'gemma4')
      b = routing::AttemptTargetKey.new(provider_family: 'vllm', instance_id: 'helios1', model: 'gemma4')
      expect(a).not_to eq(b)
    end

    it 'constructs QuotaDomainKey with (provider_family:, opaque_id:)' do
      qd = routing::QuotaDomainKey.new(provider_family: 'openai', opaque_id: 'proj-1')
      expect(qd.provider_family).to eq(:openai)
      expect(qd.opaque_id).to eq('proj-1')
    end

    it 'constructs Exclusion with the exact kwargs' do
      atk = routing::AttemptTargetKey.new(provider_family: 'vllm', instance_id: 'h200', model: 'gemma4')
      exclusion = routing::Exclusion.new(
        target_kind: :attempt_target, target: atk, reason: 'attempt_consumed',
        evidence: { attempt_number: 1 }, lifetime: :request
      )
      expect(exclusion.target_kind).to eq(:attempt_target)
      expect(exclusion.target).to eq(atk)
    end

    it 'exposes Selection#attempt_target_key' do
      expect(routing::Selection.instance_methods).to include(:attempt_target_key)
    end

    it 'constructs a Rejection with the exact kwargs' do
      rejection = routing::Rejection.new(
        kind: :too_early, reason: 'incomplete', inventory_generation: 0,
        candidate_counts: {}, explicit_pins: {}, http_status: nil, code: nil
      )
      expect(rejection.kind).to eq(:too_early)
    end

    it 'constructs a BodyModelHintDecision with the exact kwargs' do
      decision = routing::BodyModelHintDecision.new(
        requested_model: 'gpt-5-nano', disposition: :ignored_blacklisted,
        model_constraint: nil, matched_whitelist: nil, matched_blacklist: 'nano',
        settings_generation: 1
      )
      expect(decision.disposition).to eq(:ignored_blacklisted)
    end

    it 'constructs a ProviderOutcome with the exact kwargs' do
      outcome = routing::ProviderOutcome.new(
        kind: :provider_error, reason: 'ServerError', quota_domain: nil, retry_after: nil, metadata: {}
      )
      expect(outcome.kind).to eq(:provider_error)
    end
  end

  describe 'snapshot and registry API' do
    it 'exposes the allowed snapshot reads' do
      %i[instance offering lane lanes_for offerings_for publication_status
         each_instance each_lane each_offering each_publication_status].each do |m|
        expect(inventory::Snapshot.instance_methods).to include(m), "Snapshot##{m} missing"
      end
    end

    it 'exposes the allowed registry calls' do
      %i[snapshot acquire dispatch_instance_unavailable claim_instance
         activate_instance_snapshot replace_instance_snapshot readiness_probe_started
         readiness_succeeded readiness_failed remove_instance reset!].each do |m|
        expect(inventory::Registry).to respond_to(m), "Registry.#{m} missing"
      end
    end

    it 'exposes empty snapshot enumerators without a block' do
      inventory::Registry.reset!
      snapshot = inventory::Registry.snapshot
      expect(snapshot.each_instance).to be_a(Enumerator)
      expect(snapshot.each_publication_status).to be_a(Enumerator)
      expect(snapshot.each_lane).to be_a(Enumerator)
      expect(snapshot.each_offering).to be_a(Enumerator)
    end
  end

  describe 'provider runtime normalization contract' do
    it 'exposes Provider#normalize_dispatch_error' do
      expect(Legion::Extensions::Llm::Provider.instance_methods).to include(:normalize_dispatch_error)
    end
  end
end
