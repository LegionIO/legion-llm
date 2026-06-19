# frozen_string_literal: true

require 'spec_helper'

# G25 / h200 C1 / PR #152 C5/C6 — P5 commit 1
RSpec.describe 'Internal error is terminal — no retry (P5)' do
  include Legion::Logging::Helper

  let(:executor_class) { Legion::LLM::Inference::Executor }

  def build_lane(provider: :vllm, instance: :a, model: 'gemma-12b', tier: :direct)
    {
      id:              "#{tier}:#{provider}:#{instance}:inference:#{model}",
      tier:            tier,
      provider_family: provider,
      instance_id:     instance,
      model:           model,
      type:            :inference,
      capabilities:    [],
      limits:          { context_window: 200_000 },
      cost:            { input: 0.0, output: 0.0 },
      enabled:         true,
      lane_weight:     100_000_000,
      health:          { circuit_state: :closed, denied: false, available: true, adjustment: 0 },
      expires_at:      nil
    }
  end

  it 'internal_error? returns true for NoMethodError and ArgumentError' do
    executor = executor_class.allocate
    expect(executor.send(:internal_error?, NoMethodError.new('typo'))).to be true
    expect(executor.send(:internal_error?, ArgumentError.new('bad arg'))).to be true
    expect(executor.send(:internal_error?, RuntimeError.new('transient'))).to be false
    expect(executor.send(:internal_error?, StandardError.new('whatever'))).to be false
  end

  it 'classify_error returns :internal_error for NoMethodError before :account_specific check' do
    executor = executor_class.allocate

    # An error that would match account_specific pattern but is also a NoMethodError
    err = NoMethodError.new('credit balance exceeded')
    expect(executor.send(:classify_error, error: err)).to eq(:internal_error)
  end

  it 'classify_error returns :transient for runtime errors' do
    executor = executor_class.allocate
    expect(executor.send(:classify_error, error: RuntimeError.new('timeout'))).to eq(:transient)
  end

  it 'classify_and_accumulate_exclusions re-raises internal_error immediately' do
    executor = executor_class.allocate
    lane = build_lane
    payload = { tried_lanes: [] }
    error = NoMethodError.new('typo in shared code')

    expect { executor.send(:classify_and_accumulate_exclusions, error: error, lane: lane, payload: payload) }
      .to raise_error(NoMethodError, 'typo in shared code')
    expect(payload[:tried_lanes]).to be_empty
  end

  it 'classify_and_accumulate_exclusions does NOT call health_tracker for internal_error' do
    executor = executor_class.allocate
    lane = build_lane
    payload = { tried_lanes: [] }
    error = NoMethodError.new('typo')

    expect(Legion::LLM::Router.health_tracker).not_to receive(:trip_circuit)
    expect(Legion::LLM::Router.health_tracker).not_to receive(:report)

    expect { executor.send(:classify_and_accumulate_exclusions, error: error, lane: lane, payload: payload) }
      .to raise_error(NoMethodError)
  end

  it 'classify_and_accumulate_exclusions pushes lane to tried_lanes for transient error' do
    executor = executor_class.allocate
    lane = build_lane
    payload = { tried_lanes: [] }
    error = RuntimeError.new('transient failure')

    executor.send(:classify_and_accumulate_exclusions, error: error, lane: lane, payload: payload)
    expect(payload[:tried_lanes]).to include(lane[:id])
  end
end
