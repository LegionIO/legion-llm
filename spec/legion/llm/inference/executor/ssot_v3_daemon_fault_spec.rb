# frozen_string_literal: true

require 'spec_helper'
require 'legion/llm/inference/executor'
require 'legion/llm/call/selection_dispatch'
require 'legion/extensions/llm/inventory/errors'

RSpec.describe 'SSOT v3 daemon and lease fault classification', :ssot_v3 do
  let(:errors) { Legion::Extensions::Llm::Inventory::Errors }

  def context_for(instance_id:, callable: nil, operation: :chat)
    activate(
      provider_family: 'vllm', instance_id: instance_id,
      drafts: [offering_draft(model: 'gemma4', supported: [operation],
                              capabilities: { streaming: :supported }, context: 200_000)],
      callable: callable
    )
    snap = snapshot
    selection = selection_for(
      snapshot: snap, provider_family: 'vllm', instance_id: instance_id,
      model: 'gemma4', operation: operation
    )
    Legion::LLM::Inference::AttemptContext.build(selection: selection, snapshot: snap, attempt_number: 1)
  end

  it 're-raises ArgumentError and TypeError raw before provider normalization' do
    [ArgumentError, TypeError].each_with_index do |error_class, index|
      callable = SsotV3SnapshotFactory::FactoryCallable.new(
        responder: ->(_operation, _args, _kwargs, _block) { raise error_class, 'daemon contract fault' }
      )
      context = context_for(instance_id: "daemon-#{index}", callable: callable)
      expect do
        Legion::LLM::Call::SelectionDispatch.call(
          attempt_context: context, arguments: { messages: [] }
        )
      end.to raise_error(error_class, 'daemon contract fault')
      expect(context.selection.callable_handle.reference_count).to eq(0)
    end
  end

  it 'turns a synchronous stale lease into instance_unavailable rather than provider_error' do
    request = Legion::LLM::Inference::Request.build_for_test(messages: [], routing_seed: '00' * 16)
    executor = Legion::LLM::Inference::Executor.new(request)
    allow(executor).to receive(:execute_provider_request).and_raise(errors::StaleCallableError, 'retired')

    result = executor.send(:ssot_v3_execute_attempt)

    expect(result).to be_failure
    expect(result.outcome.kind).to eq(:instance_unavailable)
  end

  it 'retries stream preflight after a stale lease and selects the next available lane' do
    first = context_for(instance_id: 'first', operation: :stream_chat)
    context_for(instance_id: 'second', operation: :stream_chat)
    request = Legion::LLM::Inference::Request.build_for_test(
      messages: [], stream: true, routing: { model: 'gemma4' }, routing_seed: 'ab' * 16
    )
    requirements = Legion::LLM::Router::RequestRequirements.build(
      request: request, operation: :stream_chat, required_capabilities: %i[streaming],
      estimated_input_bound: 1, required_output_tokens: 0
    )
    executor = Legion::LLM::Inference::Executor.new(request)
    executor.instance_variable_set(:@routing_requirements, requirements)
    calls = 0
    allow(Legion::Extensions::Llm::Inventory::Registry).to receive(:acquire).and_wrap_original do |original, **kwargs|
      calls += 1
      raise errors::StaleCallableError, 'retired' if calls == 1

      original.call(**kwargs)
    end

    lane = executor.send(:ssot_v3_stream_preflight)

    expect(calls).to eq(2)
    expect(lane[:instance_id]).not_to eq(first.selection.instance_id)
    expect(snapshot.instance(instance_key: first.selection.instance_key).availability.state).to eq(:unavailable)
  ensure
    executor&.send(:release_preflight_lease)
  end

  it 'raises a typed pre-header rejection when every bounded preflight lease is stale' do
    Legion::Settings.loader.settings[:llm][:routing][:max_attempts] = 2
    Legion::LLM::Router::SettingsState.reset!
    context_for(instance_id: 'dead-one', operation: :stream_chat)
    context_for(instance_id: 'dead-two', operation: :stream_chat)
    request = Legion::LLM::Inference::Request.build_for_test(
      messages: [], stream: true, routing: { model: 'gemma4' }, routing_seed: 'cd' * 16
    )
    requirements = Legion::LLM::Router::RequestRequirements.build(
      request: request, operation: :stream_chat, required_capabilities: %i[streaming],
      estimated_input_bound: 1, required_output_tokens: 0
    )
    executor = Legion::LLM::Inference::Executor.new(request)
    executor.instance_variable_set(:@routing_requirements, requirements)
    allow(Legion::Extensions::Llm::Inventory::Registry).to receive(:acquire)
      .and_raise(errors::CallableDisposedError, 'disposed')

    expect { executor.send(:ssot_v3_stream_preflight) }
      .to raise_error(Legion::LLM::Errors::RoutingRejected) do |error|
        expect(error.rejection.kind).to eq(:attempts_exhausted)
      end
  ensure
    Legion::Settings.loader.settings[:llm][:routing][:max_attempts] = 3
    Legion::LLM::Router::SettingsState.reset!
  end

  it 'classifies a streaming lease failure as instance_unavailable before failover' do
    context = context_for(instance_id: 'stream-failure', operation: :stream_chat)
    request = Legion::LLM::Inference::Request.build_for_test(
      messages: [], stream: true, routing_seed: 'ef' * 16
    )
    executor = Legion::LLM::Inference::Executor.new(request)
    captured = nil
    action = instance_double('OutcomeAction', disposition: :retry)
    rejection = Legion::Extensions::Llm::Routing::Rejection.new(
      kind: :service_unavailable, reason: 'none', inventory_generation: snapshot.generation,
      candidate_counts: {}, http_status: 503
    )
    session = instance_double('RoutingSession')
    allow(session).to receive(:classify) do |dispatch_result:, **|
      captured = dispatch_result.outcome
      action
    end
    allow(session).to receive(:next_attempt).and_return(rejection)
    error = errors::StaleCallableError.new('retired')

    expect do
      executor.send(:ssot_v3_stream_handle_failure, error: error, session: session, attempt_context: context)
    end.to raise_error(error)
    expect(captured.kind).to eq(:instance_unavailable)
  end
end
