# frozen_string_literal: true

require 'spec_helper'
require 'legion/llm/inference/route_attempts'
require 'legion/llm/fleet/dispatcher'
require 'legion/llm/fleet/token_issuer'

RSpec.describe Legion::LLM::Inference::RouteAttempts, :ssot_v3 do
  let(:canonical) { Legion::Extensions::Llm::Canonical }
  let(:logger) { instance_double('Logger', debug: nil, info: nil, warn: nil) }
  let(:raw_options) do
    {
      system: 'authoritative system', offering_id: 'off:v1:internal',
      offering_metadata: { secret: true }, tools: [], temperature: 0,
      params: { provider_flag: true }, headers: { 'x-test' => '1' },
      schema: nil, thinking: nil, tool_prefs: nil, top_p: 0.7, seed: 42
    }
  end
  let(:messages) do
    [
      { role: :assistant, content: '', tool_calls: [{ id: 'call-1', name: 'lookup', arguments: { query: 'status' } }] },
      { role: :tool, tool_call_id: 'call-1', content: 'clean' },
      { role: :user, content: 'hello' }
    ]
  end

  def harness(fleet:, context:, raw_options:)
    Class.new do
      include Legion::LLM::Inference::RouteAttempts

      attr_reader :captured

      define_method(:initialize) do |fleet_value, context_value, options, logger|
        @fleet_value = fleet_value
        @current_attempt_context = context_value
        @options = options
        @logger = logger
      end

      def fleet_dispatch? = @fleet_value
      def native_dispatch_options = @options
      def log = @logger
      def dispatch_direct_request(**kwargs) = (@captured = kwargs)
      def dispatch_fleet_request(**kwargs) = (@captured = kwargs)
    end.new(fleet, context, raw_options, logger)
  end

  def attempt_context(operation = :chat)
    endpoint = Struct.new(:operation).new(operation)
    Struct.new(:selection, :lane).new(endpoint, endpoint)
  end

  it 'projects and folds once before both SSOT dispatch branches' do
    direct = harness(fleet: false, context: Object.new, raw_options: raw_options)
    fleet = harness(fleet: true, context: attempt_context, raw_options: raw_options)

    [direct, fleet].each do |subject|
      subject.send(:dispatch_provider_request, capability: :chat, operation: :chat, messages: messages)
      captured = subject.captured
      expect(captured[:messages]).to all(be_a(canonical::Message))
      expect(captured[:messages].count { |message| message.role == :system }).to eq(1)
      expect(captured[:messages].first.content).to eq('authoritative system')
      options = captured[:dispatch_options]
      # N9: :headers is no longer a contract option key — it is never
      # projected onto the dispatch options (it is not populated in the SSOT
      # dispatch path, and caller headers are not fleet wire).
      expect(options.keys).to contain_exactly(:tools, :temperature, :params, :schema, :thinking, :tool_prefs)
      expect(options[:params]).to eq(provider_flag: true, top_p: 0.7, seed: 42)
      expect(options).not_to include(:system, :offering_id, :offering_metadata, :top_p, :seed, :headers)
    end
  end

  it 'replaces a prior folded system message instead of duplicating it' do
    subject = harness(fleet: false, context: Object.new, raw_options: raw_options)
    subject.send(:dispatch_provider_request, capability: :chat, operation: :chat, messages: messages)
    round_one = subject.captured[:messages]
    subject.instance_variable_set(:@options, raw_options.merge(system: 'round two continuation'))

    subject.send(:dispatch_provider_request, capability: :chat, operation: :chat, messages: round_one)

    expect(subject.captured[:messages].count { |message| message.role == :system }).to eq(1)
    expect(subject.captured[:messages].first.content).to eq('round two continuation')
  end

  it 'canonicalizes every SSOT message even when no system text is present' do
    subject = harness(fleet: false, context: Object.new, raw_options: raw_options.merge(system: nil))

    subject.send(:dispatch_provider_request, capability: :chat, operation: :chat, messages: messages)

    expect(subject.captured[:messages]).to all(be_a(canonical::Message))
    expect(subject.captured[:messages].map(&:role)).to eq(%i[assistant tool user])
    expect(subject.captured[:messages].first.tool_calls.first.name).to eq('lookup')
  end

  it 'replaces a leading hash system message exactly once without mutating the input' do
    input = [{ role: :system, content: 'stale system' }, *messages]
    original = input.map(&:dup)
    subject = harness(fleet: false, context: Object.new, raw_options: raw_options)

    subject.send(:dispatch_provider_request, capability: :chat, operation: :chat, messages: input)

    projected = subject.captured[:messages]
    expect(projected).to all(be_a(canonical::Message))
    expect(projected.count { |message| message.role == :system }).to eq(1)
    expect(projected.first.content).to eq('authoritative system')
    expect(input).to eq(original)
  end

  it 'preserves non-SSOT messages and options exactly and rejects malformed SSOT params' do
    legacy = harness(fleet: false, context: nil, raw_options: raw_options)
    legacy.send(:dispatch_provider_request, capability: :chat, operation: :chat, messages: messages)
    expect(legacy.captured[:messages]).to equal(messages)
    expect(legacy.captured[:dispatch_options]).to equal(raw_options)

    malformed = harness(fleet: false, context: Object.new, raw_options: raw_options.merge(params: false))
    expect do
      malformed.send(:dispatch_provider_request, capability: :chat, operation: :chat, messages: messages)
    end.to raise_error(ArgumentError, /dispatch params must be a Hash/)
  end

  it 'rejects a fleet selection/lane operation mismatch and preserves legacy fleet operation' do
    selection = Struct.new(:operation).new(:stream_chat)
    lane = Struct.new(:operation).new(:chat)
    mismatch = Struct.new(:selection, :lane).new(selection, lane)
    malformed = harness(fleet: true, context: mismatch, raw_options: raw_options)

    expect do
      malformed.send(:dispatch_provider_request, capability: :stream, operation: :chat, messages: messages)
    end.to raise_error(ArgumentError, %r{selection/lane operation mismatch})

    legacy = harness(fleet: true, context: nil, raw_options: raw_options)
    legacy.send(:dispatch_provider_request, capability: :stream, operation: :chat, messages: messages)
    expect(legacy.captured[:operation]).to eq(:chat)
  end

  describe 'fleet exact-execution envelope' do
    let(:legacy_payload) do
      {
        request_id: 'req', correlation_id: 'corr', idempotency_key: 'idem',
        operation: :chat, provider: 'vllm', provider_instance: 'h200', model: 'model',
        reply_to: 'reply', message_context: {}, params: {}, caller: {}, trace_context: {},
        timeout_seconds: 30, expires_at: Time.now.utc.iso8601
      }
    end

    it 'copies exact fields out of params and signs both claims' do
      allow(Legion::LLM::Fleet::Dispatcher).to receive(:dispatch_auth_required?).and_return(false)
      envelope = Legion::LLM::Fleet::Dispatcher.build_envelope(
        operation: :chat,
        request_opts: legacy_payload.merge(
          messages: messages,
          execution_contract: Legion::Extensions::Llm::Fleet::Protocol::EXACT_EXECUTION_CONTRACT,
          offering_id: 'off:v1:exact', system: 'must-not-cross'
        ),
        message_context: {}, routing_key: 'llm.request.test'
      )

      expect(envelope).to include(execution_contract: 'exact_offering_v1', offering_id: 'off:v1:exact')
      expect(envelope[:params]).not_to include(:execution_contract, :offering_id)
      claims = Legion::LLM::Fleet::TokenIssuer.required_claims(envelope.merge(legacy_payload))
      expect(claims).to include(execution_contract: 'exact_offering_v1', offering_id: 'off:v1:exact')
    end

    it 'fails closed for unknown markers and invalid exact offering ids in both layers' do
      allow(Legion::LLM::Fleet::Dispatcher).to receive(:dispatch_auth_required?).and_return(false)
      [false, 'unknown'].each do |marker|
        expect do
          Legion::LLM::Fleet::Dispatcher.build_envelope(
            operation: :chat, request_opts: legacy_payload.merge(execution_contract: marker),
            message_context: {}, routing_key: 'llm.request.test'
          )
        end.to raise_error(ArgumentError, /unknown fleet execution_contract/)
        expect do
          Legion::LLM::Fleet::TokenIssuer.required_claims(legacy_payload.merge(execution_contract: marker))
        end.to raise_error(Legion::LLM::Fleet::TokenError, /unknown fleet execution_contract/)
      end

      [nil, '', ' ', :symbol].each do |offering_id|
        expect do
          Legion::LLM::Fleet::Dispatcher.build_envelope(
            operation: :chat,
            request_opts: legacy_payload.merge(execution_contract: 'exact_offering_v1', offering_id: offering_id),
            message_context: {}, routing_key: 'llm.request.test'
          )
        end.to raise_error(ArgumentError, /nonempty String offering_id/)
      end
    end
  end
end
