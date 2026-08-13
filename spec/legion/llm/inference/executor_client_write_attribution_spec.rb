# frozen_string_literal: true

require 'spec_helper'
require 'legion/llm/api/stream_assembler'

# Regression: a CLIENT-side SSE write failure (the client socket died — VPN bounce,
# disconnect, Puma "Socket timeout writing data") was being counted as an UPSTREAM
# PROVIDER failure. It reported provider :error, tripped the vLLM lane's circuit, and
# escalated to EscalationExhausted — failing over because the CLIENT went away. Once both
# gemma-4-31b lanes tripped, every 31b request hit NoLaneAvailable until process restart.
#
# SSOT v3 rewrite: the health_tracker / circuit mechanism is replaced by the Phase 1
# Registry's dispatch_instance_unavailable. The INVARIANT survives: client-write,
# SSE/canonical-parse, and daemon/programming errors are non_provider_failure? → they
# re-raise from ssot_v3_execute_attempt without producing a ProviderOutcome, so
# OutcomeClassifier is never called and dispatch_instance_unavailable is never triggered.
#
# Genuine provider errors continue to produce a SelectionDispatch::Result.failure, and
# only :instance_unavailable outcomes trigger a GlobalTransition/dispatch_instance_unavailable.
#
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
  let(:executor_class) { described_class }

  # ─── Section 1: non_provider_failure? predicate ────────────────────────────────
  # Replaces the old #record_escalation_failure tests which called health_tracker.
  # In SSOT v3 the predicate non_provider_failure? is the single gate: true → re-raise
  # immediately (no ProviderOutcome, no OutcomeClassifier, no dispatch_instance_unavailable).

  describe '#non_provider_failure? (was: #record_escalation_failure attribution)' do
    let(:executor) { executor_class.allocate }

    context 'CLIENT-WRITE / disconnect errors' do
      ClientWriteAttributionFixtures.client_write.each do |label, builder|
        it "returns true for #{label}" do
          err = instance_exec(&builder)
          expect(executor.send(:non_provider_failure?, err)).to be true
        end
      end
    end

    context 'SSE / canonical-parse errors (LegionIO bugs)' do
      ClientWriteAttributionFixtures.sse_parse.each do |label, builder|
        it "returns true for #{label}" do
          err = instance_exec(&builder)
          expect(executor.send(:non_provider_failure?, err)).to be true
        end
      end
    end

    context 'daemon / programming errors' do
      ClientWriteAttributionFixtures.daemon.each do |label, builder|
        it "returns true for #{label}" do
          err = instance_exec(&builder)
          expect(executor.send(:non_provider_failure?, err)).to be true
        end
      end
    end

    context 'CONTRAST: genuine provider errors' do
      it 'returns false for a provider 5xx (Faraday::ServerError)' do
        expect(executor.send(:non_provider_failure?, Faraday::ServerError.new('503'))).to be false
      end

      it 'returns false for connection-refused TO the provider (Faraday::ConnectionFailed)' do
        expect(executor.send(:non_provider_failure?, Faraday::ConnectionFailed.new('refused'))).to be false
      end

      it 'returns false for Legion::LLM::AuthError' do
        expect(executor.send(:non_provider_failure?, Legion::LLM::AuthError.new('Unauthorized'))).to be false
      end
    end
  end

  # ─── Section 2: ssot_v3_execute_attempt re-raise path ─────────────────────────
  # Replaces the old #report_provider_failure tests. In SSOT v3, ssot_v3_execute_attempt
  # is the single execution gate: non-provider failures propagate immediately; provider
  # errors return a SelectionDispatch::Result.failure.

  describe '#ssot_v3_execute_attempt (was: #report_provider_failure)' do
    let(:executor) { executor_class.allocate }

    ClientWriteAttributionFixtures.non_provider_all.each do |label, builder|
      it "re-raises #{label} without producing a ProviderOutcome" do
        err = instance_exec(&builder)
        allow(executor).to receive(:execute_provider_request).and_raise(err)

        expect { executor.send(:ssot_v3_execute_attempt) }.to raise_error(err.class)
      end
    end

    it 'CONTRAST: returns a failure SelectionDispatch::Result for a genuine provider 5xx' do
      err = Legion::LLM::ProviderError.new('provider returned 502')
      allow(executor).to receive(:execute_provider_request).and_raise(err)

      result = executor.send(:ssot_v3_execute_attempt)
      expect(result).to be_a(Legion::LLM::Call::SelectionDispatch::Result)
      expect(result.failure?).to be true
      expect(result.outcome.kind).to eq(:provider_error)
    end
  end

  # ─── Section 3: dispatch_instance_unavailable isolation ──────────────────────
  # Replaces the old #classify_and_accumulate_exclusions tests.
  # Key invariants:
  #   (a) Non-provider failures re-raise from ssot_v3_execute_attempt → OutcomeClassifier
  #       is never called → dispatch_instance_unavailable is never called.
  #   (b) Provider errors produce a failure Result → OutcomeClassifier classifies them →
  #       only :instance_unavailable triggers dispatch_instance_unavailable.

  describe 'dispatch_instance_unavailable isolation (was: #classify_and_accumulate_exclusions)' do
    let(:executor) { executor_class.allocate }

    it 're-raises a client-write error without calling OutcomeClassifier or dispatch_instance_unavailable' do
      err = ::Puma::ConnectionError.new('Socket timeout writing data')
      allow(executor).to receive(:execute_provider_request).and_raise(err)

      expect(Legion::Extensions::Llm::Inventory::Registry).not_to receive(:dispatch_instance_unavailable)
      expect(Legion::LLM::Router::OutcomeClassifier).not_to receive(:call)

      expect { executor.send(:ssot_v3_execute_attempt) }.to raise_error(::Puma::ConnectionError)
    end

    it 're-raises an SSE/parse error without calling OutcomeClassifier or dispatch_instance_unavailable' do
      err = Legion::JSON::ParseError.new('unexpected token')
      allow(executor).to receive(:execute_provider_request).and_raise(err)

      expect(Legion::Extensions::Llm::Inventory::Registry).not_to receive(:dispatch_instance_unavailable)
      expect(Legion::LLM::Router::OutcomeClassifier).not_to receive(:call)

      expect { executor.send(:ssot_v3_execute_attempt) }.to raise_error(Legion::JSON::ParseError)
    end

    it 'CONTRAST: provider error produces a failure Result eligible for OutcomeClassifier' do
      err = Faraday::ServerError.new('503')
      allow(executor).to receive(:execute_provider_request).and_raise(err)

      result = executor.send(:ssot_v3_execute_attempt)
      expect(result.failure?).to be true
      # The failure result is what gets passed to OutcomeClassifier by the RoutingSession.
      # :provider_error is RETRYABLE, so it will NOT trigger dispatch_instance_unavailable.
      expect(result.outcome.kind).to eq(:provider_error)
    end
  end
end
