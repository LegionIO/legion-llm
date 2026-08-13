# frozen_string_literal: true

require 'spec_helper'
require 'legion/llm/router/outcome_classifier'
require 'legion/llm/inference/attempt_context'

# Escalation error classification — SSOT v3 rewrite.
#
# INVARIANTS (all survive):
#   • Request-payload validation errors (ValidationException) → :invalid_request →
#     OutcomeClassifier terminal, NO global_transition → dispatch_instance_unavailable never called.
#   • Auth / authorization errors → :authentication/:authorization → OutcomeClassifier retry,
#     NO global_transition → instance stays available for future requests.
#   • Transport/connection errors → :provider_error → OutcomeClassifier retry, NO global_transition.
#   • Context overflow → :provider_error → OutcomeClassifier retry, NO global_transition.
#   • Only :instance_unavailable triggers a GlobalTransition → dispatch_instance_unavailable.
#
# What changed vs legacy: health_tracker.deny_model / health_tracker.trip_circuit no longer exist.
# The equivalent in SSOT v3 is OutcomeClassifier.Action#global_transition — only
# :instance_unavailable produces one. All other outcomes are request-local.
RSpec.describe Legion::LLM::Inference::Executor, 'escalation error classification', :ssot_v3 do
  let(:routing) { Legion::Extensions::Llm::Routing }

  # Build an AttemptContext for the given provider/instance using the Phase 1 Registry.
  def build_attempt_context(provider_family: 'bedrock', instance_id: 'primary', model: 'claude-sonnet')
    activate(provider_family: provider_family, instance_id: instance_id,
             drafts: [offering_draft(model: model, supported: %i[chat], context: 200_000)])
    snap = snapshot
    sel = selection_for(snapshot: snap, provider_family: provider_family,
                        instance_id: instance_id, model: model, operation: :chat)
    Legion::LLM::Inference::AttemptContext.build(selection: sel, snapshot: snap, attempt_number: 1)
  end

  def make_outcome(kind, reason: kind.to_s)
    routing::ProviderOutcome.new(kind: kind, reason: reason)
  end

  def classify_outcome(kind, attempt_context:, attempts_remaining: 2, reason: kind.to_s)
    outcome = make_outcome(kind, reason: reason)
    Legion::LLM::Router::OutcomeClassifier.call(
      outcome: outcome, attempt_context: attempt_context,
      attempts_remaining: attempts_remaining
    )
  end

  describe 'OutcomeClassifier disposition — request-payload validation errors' do
    let(:attempt_context) { build_attempt_context }

    it 'invalid_request (ValidationException) → terminal action, no global_transition' do
      # ValidationException errors are normalized to :invalid_request by the provider.
      # OutcomeClassifier marks them terminal — they never waste additional attempt slots.
      action = classify_outcome(:invalid_request, attempt_context: attempt_context,
                                                  reason:          'ValidationException: tools.16.custom.input_schema.type: Field required')
      expect(action).to be_terminal
      expect(action.global_transition).to be_nil
    end

    it 'invalid_request for messages validation errors → terminal action, no global_transition' do
      action = classify_outcome(:invalid_request, attempt_context: attempt_context,
                                                  reason:          'ValidationException: messages.3.content: Field required')
      expect(action).to be_terminal
      expect(action.global_transition).to be_nil
    end
  end

  describe 'OutcomeClassifier disposition — auth / authorization errors' do
    let(:attempt_context) { build_attempt_context }

    it 'authorization → retry action, no global_transition (model not permanently denied)' do
      # In SSOT v3, AccessDeniedException maps to :authorization which is RETRYABLE.
      # The consumed-target exclusion prevents reselecting this exact lane, but
      # the instance is NOT marked globally unavailable.
      action = classify_outcome(:authorization, attempt_context: attempt_context,
                                                reason:          'AccessDeniedException: not authorized for model X')
      expect(action).to be_retry
      expect(action.global_transition).to be_nil
    end

    it 'authentication → retry action, no global_transition' do
      action = classify_outcome(:authentication, attempt_context: attempt_context,
                                                 reason:          'Unauthorized')
      expect(action).to be_retry
      expect(action.global_transition).to be_nil
    end
  end

  describe 'OutcomeClassifier disposition — transport / connection errors' do
    let(:attempt_context) { build_attempt_context }

    it 'provider_error (connection refused to provider) → retry action, no global_transition' do
      # Provider-side transport errors are retryable via a different lane.
      # The failed instance is NOT marked globally unavailable — only the
      # consumed-target exclusion (request-local) prevents re-selection.
      action = classify_outcome(:provider_error, attempt_context: attempt_context,
                                                 reason:          'Faraday::ConnectionFailed: connection refused')
      expect(action).to be_retry
      expect(action.global_transition).to be_nil
    end

    it 'connection_failure → retry action, no global_transition' do
      action = classify_outcome(:connection_failure, attempt_context: attempt_context)
      expect(action).to be_retry
      expect(action.global_transition).to be_nil
    end
  end

  describe 'OutcomeClassifier disposition — context overflow' do
    let(:attempt_context) { build_attempt_context }

    it 'provider_error (context too long) → retry action, no global_transition' do
      # ContextOverflow does not affect provider health; the lane is only excluded
      # for this request (consumed-target exclusion). No dispatch_instance_unavailable.
      action = classify_outcome(:provider_error, attempt_context: attempt_context,
                                                 reason:          'Legion::LLM::ContextOverflow')
      expect(action).to be_retry
      expect(action.global_transition).to be_nil
    end
  end

  describe 'CONTRAST: only :instance_unavailable triggers a global transition' do
    let(:attempt_context) { build_attempt_context }

    it 'instance_unavailable → retry with global_transition (dispatches to Registry)' do
      action = classify_outcome(:instance_unavailable, attempt_context:    attempt_context,
                                                       attempts_remaining: 0)
      expect(action).to be_retry
      expect(action.global_transition).not_to be_nil
      expect(action.global_transition.kind).to eq(:instance_unavailable)
      expect(action.global_transition.instance_key).to eq(attempt_context.selection.instance_key)
    end
  end

  describe '#non_provider_failure? — auth errors are provider failures (not daemon/client errors)' do
    let(:request) do
      Legion::LLM::Inference::Request.build(
        messages: [{ role: :user, content: 'hello' }],
        routing:  { provider: :vllm, model: 'qwen3.6-27b' }
      )
    end

    it 'AuthError is NOT a non_provider_failure (it is a provider-side error, eligible for retry path)' do
      executor = described_class.new(request)
      err = Legion::LLM::AuthError.new('vllm:qwen3.6-27b - Unauthorized')
      expect(executor.send(:non_provider_failure?, err)).to be false
    end

    it 'ssot_v3_execute_attempt returns failure Result for AuthError (never re-raises it)' do
      executor = described_class.new(request)
      err = Legion::LLM::AuthError.new('vllm:qwen3.6-27b - Unauthorized')
      allow(executor).to receive(:execute_provider_request).and_raise(err)

      result = executor.send(:ssot_v3_execute_attempt)
      expect(result).to be_a(Legion::LLM::Call::SelectionDispatch::Result)
      expect(result.failure?).to be true
    end
  end
end
