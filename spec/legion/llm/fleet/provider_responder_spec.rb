# frozen_string_literal: true

require 'spec_helper'

# Protocol v3 responder entry (06 W9): parse → legacy-field rejection →
# required fields → explicit version → provider-family match → exact execution
# contract (required) → WorkerExecution.call (registry topology) → publish
# FleetResponse (E3: serialized Canonical::Response under :response) → ack.
RSpec.describe Legion::LLM::Fleet::ProviderResponder, :ssot_v3 do
  let(:registry) { Legion::Extensions::Llm::Inventory::Registry }

  # offering_id is merged in per-test from the activated snapshot (the exact
  # contract binds the request to the published offering).
  let(:envelope) do
    {
      protocol_version:   3,
      request_id:         'req-provider',
      correlation_id:     'corr-provider',
      idempotency_key:    'idem-provider',
      operation:          'chat',
      provider:           'vllm',
      provider_instance:  'local',
      model:              'llama3.2',
      params:             { messages: [{ role: 'user', content: 'hello' }] },
      reply_to:           'llm.fleet.reply.test',
      message_context:    { conversation_id: 'conv-1' },
      caller:             { source: 'spec' },
      trace_context:      { trace_id: 'trace-1' },
      signed_token:       'signed-token',
      timeout_seconds:    15,
      expires_at:         (Time.now.utc + 60).iso8601,
      execution_contract: 'exact_offering_v1'
    }
  end

  def activate_with_offering(callable)
    @offering_id = nil
    activate(
      provider_family: 'vllm', instance_id: 'local', callable: callable,
      drafts: [offering_draft(model: 'llama3.2', tier: :local, supported: %i[chat])]
    )
    snap = snapshot
    @offering_id = snap.offerings_for(
      instance_key: Legion::Extensions::Llm::Inventory::Identity::InstanceKey.new(
        provider_family: 'vllm', instance_id: 'local'
      )
    ).first.offering_id
  end

  before do
    Legion::Settings[:llm][:fleet] = {
      consumer:  { requeue_transient: true },
      responder: { require_auth: false, require_idempotency: true }
    }
    @fleet_response_args = nil
    @fleet_error_args = nil
    allow(Legion::Extensions::Llm::Transport::Messages::FleetResponse).to receive(:new) do |**args|
      @fleet_response_args = args
      instance_double(Legion::Extensions::Llm::Transport::Messages::FleetResponse, publish: true)
    end
    allow(Legion::Extensions::Llm::Transport::Messages::FleetError).to receive(:new) do |**args|
      @fleet_error_args = args
      instance_double(Legion::Extensions::Llm::Transport::Messages::FleetError, publish: true)
    end
  end

  it 'validates the v3 envelope, executes through the registry, publishes the serialized canonical response, and acks' do
    callable = SsotV3SnapshotFactory::FactoryCallable.new(
      responder: lambda do |_op, _args, _kwargs, _block|
        native_dispatch_result(content: 'hello back', input_tokens: 2, output_tokens: 3)
      end
    )
    activate_with_offering(callable)
    env = envelope.merge(offering_id: @offering_id)
    delivery = instance_double('Delivery', ack: true)

    result = described_class.call(
      payload:         Legion::JSON.dump(env),
      provider_family: 'vllm',
      registry:        registry,
      delivery:        delivery
    )

    expect(result).to be_a(Legion::Extensions::Llm::Canonical::Response)
    expect(result.text).to eq('hello back')
    expect(delivery).to have_received(:ack)
    expect(@fleet_response_args).to include(
      request_id:         'req-provider',
      correlation_id:     'corr-provider',
      idempotency_key:    'idem-provider',
      operation:          'chat',
      provider:           'vllm',
      provider_instance:  'local',
      model:              'llama3.2',
      reply_to:           'llm.fleet.reply.test',
      execution_contract: 'exact_offering_v1',
      offering_id:        @offering_id
    )
    # E3: the response envelope carries the serialized Canonical::Response
    # under :response — no raw content/usage/finish_reason projection.
    expect(@fleet_response_args[:response]).to include(text: 'hello back')
    expect(@fleet_response_args).not_to include(:content, :finish_reason)
  end

  it 'publishes a non-retryable fleet error and rejects without requeue on a policy failure' do
    callable = SsotV3SnapshotFactory::FactoryCallable.new
    activate_with_offering(callable)
    env = envelope.merge(offering_id: @offering_id)
    delivery = instance_double('Delivery', reject: true)

    # Pre-reserve the idempotency key so WorkerExecution fails closed with a
    # PolicyError (duplicate key) before any dispatch.
    Legion::LLM::Fleet::WorkerExecution.reset_idempotency_cache!
    Legion::LLM::Fleet::WorkerExecution.reserve_idempotency_key!(env[:idempotency_key].to_s)

    expect do
      described_class.call(
        payload:         env,
        provider_family: 'vllm',
        registry:        registry,
        delivery:        delivery
      )
    end.to raise_error(Legion::LLM::Fleet::WorkerExecution::PolicyError, /duplicate/)

    expect(delivery).to have_received(:reject).with(false)
    expect(@fleet_error_args).to include(code: 'policy_error', retryable: false)
  end

  it 'rejects envelopes missing the exact execution contract (P2)' do
    activate_with_offering(SsotV3SnapshotFactory::FactoryCallable.new)
    env = envelope.merge(offering_id: @offering_id).except(:execution_contract)
    delivery = instance_double('Delivery', reject: true)

    expect do
      described_class.call(
        payload:         env,
        provider_family: 'vllm',
        registry:        registry,
        delivery:        delivery
      )
    end.to raise_error(ArgumentError, /execution_contract is required/)
  end

  it 'rejects legacy v1 fleet fields (P4)' do
    activate_with_offering(SsotV3SnapshotFactory::FactoryCallable.new)
    env = envelope.merge(offering_id: @offering_id).merge(request_type: 'chat')
    delivery = instance_double('Delivery', reject: true)

    expect do
      described_class.call(
        payload:         env,
        provider_family: 'vllm',
        registry:        registry,
        delivery:        delivery
      )
    end.to raise_error(ArgumentError, /request_type/)
  end
end
