# frozen_string_literal: true

require 'spec_helper'
require 'legion/llm/fleet/worker_execution'

# Protocol v3 worker (06 W1/W2): registry topology only — the provider:
# argument path is deleted. Identity → policy → idempotency → exact lane
# resolution → dispatch → Canonical::Response.
RSpec.describe Legion::LLM::Fleet::WorkerExecution, :ssot_v3 do
  let(:registry) { Legion::Extensions::Llm::Inventory::Registry }

  let(:envelope) do
    {
      protocol_version:   3,
      request_id:         'req-worker',
      correlation_id:     'corr-worker',
      idempotency_key:    'idem-worker',
      operation:          :chat,
      provider:           'vllm',
      provider_instance:  'local',
      model:              'llama3.2',
      params:             { messages: [{ role: 'user', content: 'hello' }] },
      reply_to:           'llm.fleet.reply.test',
      message_context:    {},
      caller:             { source: 'spec' },
      trace_context:      {},
      signed_token:       'signed-token',
      timeout_seconds:    15,
      expires_at:         (Time.now.utc + 60).iso8601,
      execution_contract: 'exact_offering_v1',
      offering_id:        '' # filled per-test from the activated snapshot
    }
  end

  def activate_with_offering(callable, supported: %i[chat])
    activate(
      provider_family: 'vllm', instance_id: 'local', callable: callable,
      drafts: [offering_draft(model: 'llama3.2', tier: :local, supported: supported)]
    )
    # The fleet claim's offering_id is the 5-tuple lane id (D4: the field
    # name stays, the value is the composed 5 tuple).
    snapshot.lanes_for(
      instance_key: Legion::Extensions::Llm::Inventory::Identity::InstanceKey.new(
        provider_family: 'vllm', instance_id: 'local'
      )
    ).first.lane_id
  end

  def signed_envelope(env)
    env = env.dup
    env[:signed_token] = Legion::LLM::Fleet::TokenIssuer.issue(env)
    env
  end

  def install_round_trip_crypt
    jwt = Module.new do
      class << self
        attr_accessor :claims

        def issue(payload, **)
          self.claims = payload
          'signed-worker-token'
        end

        def verify(_token, **)
          claims
        end
      end
    end
    crypt = Module.new do
      define_singleton_method(:cluster_secret) { 'test-secret' }
    end
    crypt.const_set(:JWT, jwt)
    stub_const('Legion::Crypt', crypt)
  end

  before do
    Legion::Settings[:llm][:fleet] = {
      dispatch:  { token_ttl_seconds: 180 },
      consumer:  { requeue_transient: true },
      auth:      { require_signed_token: true, issuer: 'legion-llm', audience: 'lex-llm-fleet-worker',
                   algorithm: 'HS256', accepted_issuers: ['legion-llm'], max_clock_skew_seconds: 30 },
      responder: { require_auth: false, require_policy: false, require_idempotency: true }
    }
    described_class.reset_idempotency_cache!
  end

  it 'validates identity, policy, idempotency, then dispatches through the registry callable' do
    order = []
    callable = SsotV3SnapshotFactory::FactoryCallable.new(
      responder: lambda do |_op, _args, _kwargs, _block|
        native_dispatch_result(content: 'done', input_tokens: 2, output_tokens: 1)
      end
    )
    offering_id = activate_with_offering(callable)
    env = envelope.merge(offering_id: offering_id)

    allow(described_class).to receive(:validate_identity!) {
      order << :identity
      true
    }
    allow(described_class).to receive(:validate_policy!) {
      order << :policy
      true
    }
    allow(described_class).to receive(:validate_idempotency!) {
      order << :idempotency
      nil
    }

    result = described_class.call(envelope: env, registry: registry)

    expect(order).to eq(%i[identity policy idempotency])
    expect(result).to be_a(Legion::Extensions::Llm::Canonical::Response)
    expect(result.text).to eq('done')
  end

  it 'fails closed when responder auth is required and token validation fails' do
    Legion::Settings[:llm][:fleet][:responder][:require_auth] = true
    offering_id = activate_with_offering(SsotV3SnapshotFactory::FactoryCallable.new)
    env = envelope.merge(offering_id: offering_id)

    allow(Legion::LLM::Fleet::TokenValidator).to receive(:validate!)
      .and_raise(Legion::LLM::Fleet::TokenError, 'bad token')

    expect do
      described_class.call(envelope: env, registry: registry)
    end.to raise_error(described_class::PolicyError, /bad token/)
  end

  it 'rejects duplicate idempotency keys' do
    callable = SsotV3SnapshotFactory::FactoryCallable.new(
      responder: lambda do |_op, _args, _kwargs, _block|
        native_dispatch_result(content: 'done')
      end
    )
    offering_id = activate_with_offering(callable)
    env = envelope.merge(offering_id: offering_id)

    result = described_class.call(envelope: env, registry: registry)
    expect(result.text).to eq('done')

    expect do
      described_class.call(envelope: env, registry: registry)
    end.to raise_error(described_class::PolicyError, /duplicate/)
  end

  it 'atomically reserves idempotency keys before provider dispatch' do
    described_class.reserve_idempotency_key!('idem-worker')

    expect do
      described_class.reserve_idempotency_key!('idem-worker')
    end.to raise_error(described_class::PolicyError, /duplicate/)
  end

  it 'fails closed when policy enforcement is required but no engine is configured (W6)' do
    Legion::Settings[:llm][:fleet][:responder][:require_policy] = true
    offering_id = activate_with_offering(SsotV3SnapshotFactory::FactoryCallable.new)
    env = envelope.merge(offering_id: offering_id)

    expect do
      described_class.call(envelope: env, registry: registry)
    end.to raise_error(described_class::PolicyError, /policy engine/)
  end

  it 'does not burn token replay protection when provider dispatch fails before retry' do
    install_round_trip_crypt
    Legion::Settings[:llm][:fleet][:responder][:require_auth] = true
    calls = 0
    callable = SsotV3SnapshotFactory::FactoryCallable.new(
      responder: lambda do |_op, _args, _kwargs, _block|
        calls += 1
        raise 'transient' if calls == 1

        native_dispatch_result(content: 'done')
      end
    )
    offering_id = activate_with_offering(callable)
    allow(Legion::LLM::Fleet::TokenValidator).to receive(:release_replay!)
    allow(Legion::LLM::Fleet::TokenValidator).to receive(:mark_replay!)
    env = signed_envelope(envelope.merge(offering_id: offering_id))

    expect do
      described_class.call(envelope: env, registry: registry)
    end.to raise_error(RuntimeError, /transient/)

    result = described_class.call(envelope: signed_envelope(envelope.merge(offering_id: offering_id)),
                                  registry: registry)

    expect(result.text).to eq('done')
    expect(calls).to eq(2)
    expect(Legion::LLM::Fleet::TokenValidator).to have_received(:release_replay!).once
    expect(Legion::LLM::Fleet::TokenValidator).to have_received(:mark_replay!).once
  end

  it 'dispatches embedding requests against the documented 0.8.0 artifact' do
    callable = SsotV3SnapshotFactory::FactoryCallable.new(
      responder: lambda do |_op, _args, kwargs, _block|
        { text: kwargs[:text], model: kwargs[:model], embedding: [0.5, 0.25],
          usage: Legion::Extensions::Llm::Canonical::Usage.build(input_tokens: 3) }
      end
    )
    offering_id = activate_with_offering(callable, supported: %i[embed])
    env = envelope.merge(
      offering_id: offering_id,
      operation:   :embed,
      params:      { text: 'hello', dimensions: 128 }
    )

    result = described_class.call(envelope: env, registry: registry)

    expect(result).to include(text: 'hello', model: 'llama3.2', embedding: [0.5, 0.25])
    expect(result[:usage]).to be_a(Legion::Extensions::Llm::Canonical::Usage)
    expect(result[:usage].input_tokens).to eq(3)
  end
end
