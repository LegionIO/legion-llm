# frozen_string_literal: true

require 'spec_helper'
require 'legion/llm/inference/attempt_context'
require 'legion/llm/router/outcome_classifier'

RSpec.describe Legion::LLM::Router::OutcomeClassifier, :ssot_v3 do
  let(:routing) { Legion::Extensions::Llm::Routing }

  let(:attempt_context) do
    activate(provider_family: 'vllm', instance_id: 'h200',
             drafts: [offering_draft(model: 'gemma4', supported: %i[chat])])
    snap = snapshot
    sel = selection_for(snapshot: snap, provider_family: 'vllm', instance_id: 'h200',
                        model: 'gemma4', operation: :chat)
    Legion::LLM::Inference::AttemptContext.build(selection: sel, snapshot: snap, attempt_number: 1)
  end

  def outcome(kind, **rest)
    routing::ProviderOutcome.new(kind: kind, reason: kind.to_s, **rest)
  end

  def classify(kind, attempts_remaining: 2, **rest)
    described_class.call(outcome: outcome(kind, **rest), attempt_context: attempt_context,
                         attempts_remaining: attempts_remaining)
  end

  it 'success → success, no transition/rejection' do
    a = classify(:success)
    expect(a).to be_success
    expect(a.global_transition).to be_nil
    expect(a.rejection).to be_nil
  end

  it 'instance_unavailable → retry with a global transition (even at 0 remaining)' do
    a = classify(:instance_unavailable, attempts_remaining: 0)
    expect(a).to be_retry
    expect(a.global_transition.kind).to eq(:instance_unavailable)
    expect(a.global_transition.instance_key).to eq(attempt_context.selection.instance_key)
    expect(a.global_transition.publisher_token_id).to eq(attempt_context.selection.publisher_token_id)
  end

  %i[overloaded model_not_ready timeout connection_failure provider_error malformed_output
     tool_failure authentication authorization billing model_missing context_rejected].each do |kind|
    it "#{kind} → retry with no global transition when attempts remain" do
      a = classify(kind, attempts_remaining: 1)
      expect(a).to be_retry
      expect(a.global_transition).to be_nil
      expect(a.exclusions).to eq([])
    end

    it "#{kind} → terminal attempts_exhausted when no attempts remain" do
      a = classify(kind, attempts_remaining: 0)
      expect(a).to be_terminal
      expect(a.rejection.kind).to eq(:attempts_exhausted)
    end
  end

  it 'rate_limited with authoritative quota_domain → retry with quota-domain exclusion' do
    domain = routing::QuotaDomainKey.new(provider_family: 'vllm', opaque_id: 'pool-1')
    a = classify(:rate_limited, attempts_remaining: 2, quota_domain: domain)
    expect(a).to be_retry
    expect(a.exclusions.map(&:target_kind)).to eq([:quota_domain])
    expect(a.exclusions.first.target).to eq(domain)
  end

  it 'rate_limited without quota_domain → retry, consumed-target only (no extra exclusion)' do
    a = classify(:rate_limited, attempts_remaining: 2)
    expect(a).to be_retry
    expect(a.exclusions).to eq([])
  end

  %i[policy invalid_request safety_refusal].each do |kind|
    it "#{kind} → terminal" do
      a = classify(kind)
      expect(a).to be_terminal
      expect(a.global_transition).to be_nil
    end
  end

  it 'policy → policy_denied 403' do
    a = classify(:policy)
    expect(a.rejection.kind).to eq(:policy_denied)
    expect(a.rejection.http_status).to eq(403)
  end

  %i[cancelled client_disconnect].each do |kind|
    it "#{kind} → terminal preserving the outcome kind" do
      a = classify(kind)
      expect(a).to be_terminal
      expect(a.outcome.kind).to eq(kind)
    end
  end
end
