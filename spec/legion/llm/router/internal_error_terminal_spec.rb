# frozen_string_literal: true

require 'spec_helper'

# G25 / h200 C1 / PR #152 C5/C6 — SSOT v3 rewrite
#
# Internal errors (NoMethodError/ArgumentError) come from shared daemon code —
# retrying on a different lane guarantees the same crash. In SSOT v3 these are
# classified as non_provider_failure? and re-raise immediately from
# ssot_v3_execute_attempt before any ProviderOutcome is produced. Consequently:
#   • OutcomeClassifier is never called → no global_transition → no dispatch_instance_unavailable.
#   • The consumed-target exclusion is never appended (no attempt was recorded).
#   • Transient errors (plain RuntimeError) return a failure SelectionDispatch::Result and
#     let the RoutingSession accumulate a request-local consumed-target exclusion.
RSpec.describe 'Internal error is terminal — no retry (SSOT v3)' do
  include Legion::Logging::Helper

  let(:executor_class) { Legion::LLM::Inference::Executor }

  it 'internal_error? returns true for NoMethodError and ArgumentError' do
    executor = executor_class.allocate
    expect(executor.send(:internal_error?, NoMethodError.new('typo'))).to be true
    expect(executor.send(:internal_error?, ArgumentError.new('bad arg'))).to be true
    expect(executor.send(:internal_error?, RuntimeError.new('transient'))).to be false
    expect(executor.send(:internal_error?, StandardError.new('whatever'))).to be false
  end

  it 'non_provider_failure? returns true for NoMethodError (replaces :internal_error classify_error path)' do
    executor = executor_class.allocate
    # An error that would match account_specific pattern but is also a NoMethodError
    err = NoMethodError.new('credit balance exceeded')
    expect(executor.send(:non_provider_failure?, err)).to be true
    expect(executor.send(:internal_error?, err)).to be true
  end

  it 'non_provider_failure? returns false for plain RuntimeError (transient, eligible for retry)' do
    executor = executor_class.allocate
    expect(executor.send(:non_provider_failure?, RuntimeError.new('timeout'))).to be false
  end

  it 'ssot_v3_execute_attempt re-raises NoMethodError immediately (internal error terminal)' do
    executor = executor_class.allocate
    error = NoMethodError.new('typo in shared code')
    allow(executor).to receive(:execute_provider_request).and_raise(error)

    expect { executor.send(:ssot_v3_execute_attempt) }.to raise_error(NoMethodError, 'typo in shared code')
  end

  it 'ssot_v3_execute_attempt does NOT invoke OutcomeClassifier or dispatch_instance_unavailable for internal_error' do
    # Internal errors re-raise from ssot_v3_execute_attempt before classify is reached,
    # so OutcomeClassifier.call is never invoked and Registry.dispatch_instance_unavailable
    # is never called.
    executor = executor_class.allocate
    error = NoMethodError.new('typo')
    allow(executor).to receive(:execute_provider_request).and_raise(error)

    expect(Legion::Extensions::Llm::Inventory::Registry).not_to receive(:dispatch_instance_unavailable)
    expect(Legion::LLM::Router::OutcomeClassifier).not_to receive(:call)

    expect { executor.send(:ssot_v3_execute_attempt) }.to raise_error(NoMethodError)
  end

  it 'ssot_v3_execute_attempt returns a failure SelectionDispatch::Result for a transient RuntimeError' do
    executor = executor_class.allocate
    error = RuntimeError.new('transient failure')
    allow(executor).to receive(:execute_provider_request).and_raise(error)

    result = executor.send(:ssot_v3_execute_attempt)
    expect(result).to be_a(Legion::LLM::Call::SelectionDispatch::Result)
    expect(result.failure?).to be true
    expect(result.outcome.kind).to eq(:provider_error)
  end
end
