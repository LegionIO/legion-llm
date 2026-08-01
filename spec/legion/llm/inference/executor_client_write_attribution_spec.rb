# frozen_string_literal: true

require 'spec_helper'
require 'legion/llm/api/stream_assembler'

# Regression: a CLIENT-side SSE write failure (the client socket died — VPN bounce,
# disconnect, Puma "Socket timeout writing data") was being counted as an UPSTREAM
# PROVIDER failure. It reported provider :error, tripped the vLLM lane's circuit, and
# escalated to EscalationExhausted — failing over because the CLIENT went away. Once both
# gemma-4-31b lanes tripped, every 31b request hit NoLaneAvailable until process restart.
#
# The circuit breaker answers ONE question: is the upstream PROVIDER broken? These specs
# pin BOTH directions of the classification boundary in inference/executor/escalation.rb:
#   * client-write/disconnect, SSE/canonical parse, and daemon/programming errors must NOT
#     report provider health, must NOT trip a circuit, and must NOT escalate to another lane.
#   * genuine provider errors (5xx, connection-refused-to-provider, provider 401) MUST still
#     report/deny/trip + escalate exactly as before.
# Puma::ConnectionError is a RuntimeError (NOT an IOError) in production — the exact class
# the logs show tripping the circuit. Puma is not in this gem's bundle, so we reproduce the
# class faithfully: same fully-qualified name, same RuntimeError ancestry, matched by name.
unless defined?(::Puma::ConnectionError)
  ::Object.const_set(:Puma, Module.new) unless defined?(::Puma)
  ::Puma.const_set(:ConnectionError, Class.new(RuntimeError))
end

# Exception-family fixtures kept in a plain module (not describe-block constants, which the
# Lint/ConstantDefinitionInBlock cop forbids). Each value is a builder so every example gets a
# fresh instance. Puma::ConnectionError is the production culprit; the rest round out the family.
module ClientWriteAttributionFixtures
  module_function

  def client_write
    {
      'Puma::ConnectionError (socket timeout writing data)' => -> { ::Puma::ConnectionError.new('Socket timeout writing data') },
      'Errno::EPIPE (broken pipe to client)'                => -> { Errno::EPIPE.new('Broken pipe') },
      'Errno::ECONNRESET (client reset)'                    => -> { Errno::ECONNRESET.new('Connection reset by peer') },
      'IOError closed stream'                               => -> { IOError.new('closed stream') },
      'StreamAssembler::StreamClosed'                       => -> { Legion::LLM::API::StreamAssembler::StreamClosed.new('client gone') }
    }
  end

  def sse_parse
    { 'Legion::JSON::ParseError (canonical parse bug)' => -> { Legion::JSON::ParseError.new('unexpected token') } }
  end

  def daemon
    {
      'NoMethodError (daemon bug)'        => -> { NoMethodError.new("undefined method 'foo'") },
      'ArgumentError (daemon bug)'        => -> { ArgumentError.new('wrong number of arguments') },
      'NotImplementedError (daemon stub)' => -> { NotImplementedError.new('not implemented') }
    }
  end

  def non_provider_all
    client_write.merge(sse_parse).merge(daemon)
  end
end

RSpec.describe Legion::LLM::Inference::Executor, 'client-write vs provider-error attribution' do
  let(:request) do
    Legion::LLM::Inference::Request.build(
      messages: [{ role: :user, content: 'hello' }],
      routing:  { provider: :vllm, model: 'gemma-4-31b-it' }
    )
  end
  let(:executor) { described_class.new(request) }
  let(:resolution) do
    Legion::LLM::Router::Resolution.new(
      tier:        :fleet,
      provider:    :vllm,
      instance:    :h200,
      model:       'gemma-4-31b-it',
      offering_id: 'fleet:vllm:h200:inference:gemma-4-31b-it'
    )
  end

  before do
    allow(Legion::LLM::Router).to receive(:routing_enabled?).and_return(true)
    allow(Legion::LLM::Audit).to receive(:emit_prompt)
    allow(executor).to receive(:emit_escalation_attempt_metering)
    allow(executor).to receive(:emit_escalation_attempt_audit)
  end

  describe '#record_escalation_failure (the attempts-loop failure path)' do
    context 'CLIENT-WRITE / disconnect errors' do
      ClientWriteAttributionFixtures.client_write.each do |label, builder|
        it "does not report provider health, deny, or trip for #{label}" do
          err = instance_exec(&builder)
          expect(Legion::LLM::Router.health_tracker).not_to receive(:report)
          expect(Legion::LLM::Router.health_tracker).not_to receive(:deny_model)
          expect(Legion::LLM::Router.health_tracker).not_to receive(:trip_circuit)

          executor.send(:record_escalation_failure, err, resolution, Time.now,
                        outcome: :error, operation: 'llm.pipeline.attempts_loop')
        end
      end
    end

    context 'SSE / canonical-parse errors (LegionIO bugs)' do
      ClientWriteAttributionFixtures.sse_parse.each do |label, builder|
        it "does not report provider health, deny, or trip for #{label}" do
          err = instance_exec(&builder)
          expect(Legion::LLM::Router.health_tracker).not_to receive(:report)
          expect(Legion::LLM::Router.health_tracker).not_to receive(:deny_model)
          expect(Legion::LLM::Router.health_tracker).not_to receive(:trip_circuit)

          executor.send(:record_escalation_failure, err, resolution, Time.now,
                        outcome: :error, operation: 'llm.pipeline.attempts_loop')
        end
      end
    end

    context 'daemon / programming errors' do
      ClientWriteAttributionFixtures.daemon.each do |label, builder|
        it "does not report provider health, deny, or trip for #{label}" do
          err = instance_exec(&builder)
          expect(Legion::LLM::Router.health_tracker).not_to receive(:report)
          expect(Legion::LLM::Router.health_tracker).not_to receive(:deny_model)
          expect(Legion::LLM::Router.health_tracker).not_to receive(:trip_circuit)

          executor.send(:record_escalation_failure, err, resolution, Time.now,
                        outcome: :error, operation: 'llm.pipeline.attempts_loop')
        end
      end
    end

    context 'CONTRAST: genuine provider errors still reflect on provider health' do
      it 'reports provider :error for a provider 5xx (Faraday::ServerError)' do
        err = Faraday::ServerError.new('the server responded with status 503')
        expect(Legion::LLM::Router.health_tracker).to receive(:report).with(
          hash_including(provider: :vllm, instance: :h200, signal: :error)
        )
        executor.send(:record_escalation_failure, err, resolution, Time.now,
                      outcome: :error, operation: 'llm.pipeline.attempts_loop')
      end

      it 'reports provider :error for connection-refused TO the provider' do
        err = Faraday::ConnectionFailed.new('Failed to open TCP connection to h200:8000')
        expect(Legion::LLM::Router.health_tracker).to receive(:report).with(
          hash_including(provider: :vllm, instance: :h200, signal: :error)
        )
        executor.send(:record_escalation_failure, err, resolution, Time.now,
                      outcome: :error, operation: 'llm.pipeline.attempts_loop')
      end

      it 'denies the model and trips the circuit for a provider 401 (AuthError)' do
        err = Legion::LLM::AuthError.new('vllm:gemma-4-31b-it - Unauthorized')
        expect(Legion::LLM::Router.health_tracker).to receive(:deny_model).with(
          hash_including(provider: :vllm, model: 'gemma-4-31b-it')
        )
        expect(Legion::LLM::Router.health_tracker).to receive(:trip_circuit).with(
          hash_including(provider: :vllm, instance: :h200)
        )
        executor.send(:record_escalation_failure, err, resolution, Time.now,
                      outcome: :error, operation: 'llm.pipeline.attempts_loop')
      end
    end
  end

  describe '#report_provider_failure (top-level single/stream rescue path)' do
    before do
      executor.instance_variable_set(:@resolved_provider, :vllm)
      executor.instance_variable_set(:@resolved_instance, :h200)
      executor.instance_variable_set(:@resolved_model, 'gemma-4-31b-it')
    end

    ClientWriteAttributionFixtures.non_provider_all.each do |label, builder|
      it "does not report provider health, deny, or trip for #{label}" do
        err = instance_exec(&builder)
        expect(Legion::LLM::Router.health_tracker).not_to receive(:report)
        expect(Legion::LLM::Router.health_tracker).not_to receive(:deny_model)
        expect(Legion::LLM::Router.health_tracker).not_to receive(:trip_circuit)

        executor.send(:report_provider_failure, err, status: 'provider_error')
      end
    end

    it 'CONTRAST: still reports provider :error for a genuine provider 5xx' do
      err = Legion::LLM::ProviderError.new('provider returned 502')
      expect(Legion::LLM::Router.health_tracker).to receive(:report).with(
        hash_including(provider: :vllm, instance: :h200, signal: :error)
      )
      executor.send(:report_provider_failure, err, status: 'provider_error')
    end
  end

  describe '#classify_error' do
    it 'classifies client-write/disconnect as :non_provider (terminal, no escalation)' do
      expect(executor.send(:classify_error, error: ::Puma::ConnectionError.new('Socket timeout writing data')))
        .to eq(:non_provider)
      expect(executor.send(:classify_error, error: Errno::EPIPE.new('Broken pipe'))).to eq(:non_provider)
    end

    it 'classifies SSE/canonical parse errors as :non_provider' do
      expect(executor.send(:classify_error, error: Legion::JSON::ParseError.new('bad json'))).to eq(:non_provider)
    end

    it 'classifies a genuine transport/provider error as :transient (escalatable)' do
      expect(executor.send(:classify_error, error: Faraday::ServerError.new('503'))).to eq(:transient)
    end
  end

  describe '#classify_and_accumulate_exclusions' do
    let(:lane) { { id: 'fleet:vllm:h200:inference:gemma-4-31b-it', provider_family: :vllm, instance_id: :h200 } }
    let(:payload) { { tried_lanes: [] } }

    it 're-raises a client-write error terminally without touching tried_lanes or the circuit' do
      err = ::Puma::ConnectionError.new('Socket timeout writing data')
      expect(Legion::LLM::Router.health_tracker).not_to receive(:trip_circuit)

      expect do
        executor.send(:classify_and_accumulate_exclusions, error: err, lane: lane, payload: payload)
      end.to raise_error(::Puma::ConnectionError)
      expect(payload[:tried_lanes]).to be_empty
    end

    it 're-raises an SSE/parse error terminally without touching tried_lanes' do
      err = Legion::JSON::ParseError.new('unexpected token')
      expect do
        executor.send(:classify_and_accumulate_exclusions, error: err, lane: lane, payload: payload)
      end.to raise_error(Legion::JSON::ParseError)
      expect(payload[:tried_lanes]).to be_empty
    end

    it 'CONTRAST: a genuine transient provider error is excluded and the lane is tried (accumulated)' do
      err = Faraday::ServerError.new('503')
      executor.send(:classify_and_accumulate_exclusions, error: err, lane: lane, payload: payload)
      expect(payload[:tried_lanes]).to eq([lane[:id]])
    end
  end
end
