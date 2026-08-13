# frozen_string_literal: true

require 'spec_helper'
require 'legion/llm/router/request_requirements'
require 'legion/llm/inference/routing_session'
require 'legion/llm/call/selection_dispatch'

RSpec.describe Legion::LLM::Inference::RoutingSession, :ssot_v3 do
  def build_session(seed: 'ab' * 16, model: 'gemma4', max_attempts: nil)
    routing = { model: model }.compact
    request = Legion::LLM::Inference::Request.build_for_test(routing_seed: seed, messages: [], routing: routing)
    reqs = Legion::LLM::Router::RequestRequirements.build(
      request: request, operation: :chat, required_capabilities: [],
      estimated_input_bound: 10, required_output_tokens: 0
    )
    reqs = override_max_attempts(reqs, max_attempts) if max_attempts
    described_class.new(request: request, requirements: reqs)
  end

  # Requirements is immutable; for the exhaustion test we lower the ceiling by
  # constructing a fresh requirements with a custom maximum via settings.
  def override_max_attempts(_reqs, max_attempts)
    Legion::Settings.loader.settings[:llm][:routing][:max_attempts] = max_attempts
    Legion::LLM::Router::SettingsState.reset!
    request = Legion::LLM::Inference::Request.build_for_test(routing_seed: 'ef' * 16, messages: [],
                                                             routing: { model: 'gemma4' })
    Legion::LLM::Router::RequestRequirements.build(
      request: request, operation: :chat, required_capabilities: [],
      estimated_input_bound: 10, required_output_tokens: 0
    )
  end

  after do
    Legion::Settings.loader.settings[:llm][:routing][:max_attempts] = 3
    Legion::LLM::Router::SettingsState.reset!
  end

  def two_instances
    activate(provider_family: 'vllm', instance_id: 'h200',
             drafts: [offering_draft(model: 'gemma4', supported: %i[chat], context: 200_000)])
    activate(provider_family: 'vllm', instance_id: 'helios1',
             drafts: [offering_draft(model: 'gemma4', supported: %i[chat], context: 200_000)])
  end

  it 'returns an AttemptContext and consumes its target before dispatch' do
    two_instances
    session = build_session
    ctx = session.next_attempt(snapshot: snapshot)
    expect(ctx).to be_a(Legion::LLM::Inference::AttemptContext)
    expect(session.attempt_count).to eq(1)
    expect(session.consumed_targets).to include(ctx.selection.attempt_target_key)
  end

  it 'selects a different eligible target on the next attempt (one-and-done)' do
    two_instances
    session = build_session
    first = session.next_attempt(snapshot: snapshot)
    second = session.next_attempt(snapshot: snapshot)
    expect(second).to be_a(Legion::LLM::Inference::AttemptContext)
    expect(second.selection.attempt_target_key).not_to eq(first.selection.attempt_target_key)
  end

  it 'returns attempts_exhausted once the ceiling is reached' do
    two_instances
    session = build_session(max_attempts: 1)
    session.next_attempt(snapshot: snapshot)
    result = session.next_attempt(snapshot: snapshot)
    expect(result).to be_a(Legion::Extensions::Llm::Routing::Rejection)
    expect(result.kind).to eq(:attempts_exhausted)
  end

  it 'next_attempt! raises RoutingRejected on a cold registry' do
    session = build_session
    expect { session.next_attempt!(snapshot: snapshot) }
      .to raise_error(Legion::LLM::Errors::RoutingRejected) { |e| expect(e.rejection.kind).to eq(:too_early) }
  end

  it 'classify(instance_unavailable) applies the exact-instance global transition' do
    two_instances
    session = build_session
    ctx = session.next_attempt(snapshot: snapshot)
    outcome = Legion::Extensions::Llm::Routing::ProviderOutcome.new(
      kind: :instance_unavailable, reason: 'explicit service unavailable'
    )
    result = Legion::LLM::Call::SelectionDispatch::Result.failure(outcome: outcome)
    action = session.classify(dispatch_result: result, attempt_context: ctx)
    expect(action).to be_retry
    # The exact instance is now unavailable in the registry snapshot.
    key = ctx.selection.instance_key
    fresh = Legion::Extensions::Llm::Inventory::Registry.snapshot
    expect(fresh.instance(instance_key: key).availability.state).to eq(:unavailable)
  end

  it 'classify(provider_error) is a request-local retry with no global transition' do
    two_instances
    session = build_session
    ctx = session.next_attempt(snapshot: snapshot)
    outcome = Legion::Extensions::Llm::Routing::ProviderOutcome.new(kind: :provider_error, reason: 'boom')
    result = Legion::LLM::Call::SelectionDispatch::Result.failure(outcome: outcome)
    action = session.classify(dispatch_result: result, attempt_context: ctx)
    expect(action).to be_retry
    expect(action.global_transition).to be_nil
    key = ctx.selection.instance_key
    fresh = Legion::Extensions::Llm::Inventory::Registry.snapshot
    expect(fresh.instance(instance_key: key).availability.state).to eq(:available)
  end
end
