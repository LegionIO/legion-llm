# frozen_string_literal: true

require 'spec_helper'
require 'legion/llm/inference/route_attempts'
require 'legion/llm/inference/attempt_context'
require 'legion/llm/fleet/dispatcher'
require 'legion/llm/fleet/worker_execution'

RSpec.describe Legion::LLM::Inference::RouteAttempts, :ssot_v3 do
  let(:canonical) { Legion::Extensions::Llm::Canonical }
  let(:logger) { instance_double('Logger', debug: nil, info: nil, warn: nil) }
  let(:request) do
    instance_double(
      Legion::LLM::Inference::Request,
      id: 'req-stream', conversation_id: 'conv-stream', idempotency_key: 'idem-stream',
      caller: { source: 'spec' }, ttl: 30
    )
  end
  let(:messages) { [canonical::Message.build(role: :user, content: 'hello')] }

  def fleet_harness(context:, request:, logger:)
    Class.new do
      include Legion::LLM::Inference::RouteAttempts

      define_method(:initialize) do |attempt_context, request_value, logger_value|
        selection = attempt_context.selection
        @current_attempt_context = attempt_context
        @request = request_value
        @logger = logger_value
        @resolved_provider = selection.provider_family
        @resolved_instance = selection.instance_id
        @resolved_model = selection.model
        @resolved_tier = :fleet
        @resolved_offering_id = selection.offering_id
        @resolved_offering_metadata = {}
        @tracing = {}
      end

      def fleet_dispatch? = true
      def native_dispatch_options = { tools: [], params: {} }
      def log = @logger
      def record_route_attempt(**) = nil
      def normalize_offering_metadata(value) = value
    end.new(context, request, logger)
  end

  def install_round_trip_crypt
    jwt = Module.new do
      class << self
        attr_accessor :claims

        def issue(payload, **)
          self.claims = payload
          'signed-stream-token'
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

  around do |example|
    previous = Marshal.load(Marshal.dump(Legion::Settings[:llm][:fleet]))
    example.run
  ensure
    Legion::Settings[:llm][:fleet] = previous
  end

  before do
    install_round_trip_crypt
    Legion::Settings[:llm][:fleet] = {
      dispatch:  {
        enabled: true, routing_style: :shared_lane, require_auth: true,
        token_ttl_seconds: 180, timeout_seconds: 30
      },
      auth:      {
        require_signed_token: true, issuer: 'legion-llm', audience: 'lex-llm-fleet-worker',
        algorithm: 'HS256', accepted_issuers: ['legion-llm'], max_clock_skew_seconds: 30
      },
      responder: { require_auth: true, require_policy: false, require_idempotency: true }
    }
    Legion::LLM::Fleet::TokenValidator.reset_replay_cache!
    Legion::LLM::Fleet::WorkerExecution.reset_idempotency_cache!
  end

  it 'signs and executes the selected stream_chat operation even when the native loop requests chat' do
    calls = []
    callable = SsotV3SnapshotFactory::FactoryCallable.new(
      responder: lambda do |operation, _args, _kwargs, _block|
        calls << operation
        native_dispatch_result(content: 'streamed')
      end
    )
    activate(
      provider_family: 'vllm', instance_id: 'fleet-one', callable: callable,
      drafts: [offering_draft(model: 'stream-model', tier: :fleet, supported: %i[chat stream_chat])]
    )
    snap = snapshot
    selection = selection_for(
      snapshot: snap, provider_family: 'vllm', instance_id: 'fleet-one',
      model: 'stream-model', operation: :stream_chat
    )
    context = Legion::LLM::Inference::AttemptContext.build(selection: selection, snapshot: snap, attempt_number: 1)
    subject = fleet_harness(context: context, request: request, logger: logger)
    captured_envelope = nil
    worker_result = nil
    allow(Legion::LLM::Fleet::ReplyDispatcher).to receive(:agent_queue_name).and_return('reply.test')
    allow(Legion::LLM::Fleet::Dispatcher).to receive(:fleet_available?).and_return(true)
    allow(Legion::LLM::Fleet::Dispatcher).to receive(:register_response).and_return(Object.new)
    allow(Legion::LLM::Fleet::Dispatcher).to receive(:publish_request) do |**envelope|
      captured_envelope = envelope
      worker_result = Legion::LLM::Fleet::WorkerExecution.call(
        envelope: envelope, registry: Legion::Extensions::Llm::Inventory::Registry
      )
      { accepted: true }
    end
    allow(Legion::LLM::Fleet::Dispatcher).to receive(:wait_for_response) do
      { success: true, content: worker_result.text }
    end

    subject.send(:dispatch_provider_request, capability: :stream, operation: :chat, messages: messages)

    expect(captured_envelope[:operation]).to eq(:stream_chat)
    expect(Legion::Crypt::JWT.claims[:operation]).to eq(:stream_chat)
    expect(calls).to eq([:stream_chat])
    expect do
      Legion::LLM::Fleet::TokenValidator.validate!(
        token: captured_envelope[:signed_token], envelope: captured_envelope.merge(operation: :chat),
        record_replay: false
      )
    end.to raise_error(Legion::LLM::Fleet::TokenError, /operation claim mismatch/)
  end
end
