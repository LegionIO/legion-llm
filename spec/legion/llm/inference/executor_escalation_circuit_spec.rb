# frozen_string_literal: true

require 'spec_helper'
require 'legion/llm/router'

# Executor circuit-guard tests — SSOT v4 rewrite.
#
# In SSOT v4 there is no HealthTracker / circuit concept. The equivalent is:
#   • dispatch_instance_unavailable marks an exact instance unavailable globally,
#     so Router#next_lane filters it from all subsequent live inventory reads.
#   • Provider errors that are NOT :instance_unavailable are request-local (consumed-target
#     exclusion only). The instance remains available to other requests.
#
# The INVARIANTS all survive:
#   1. An unavailable instance is skipped; the next eligible lane is used.
#   2. When ALL instances are unavailable → typed Rejection → RoutingRejected (503).
#   3. Empty registry → RoutingRejected (early Rejection kind).
#   4. A credit/auth error on the first instance causes retry on a sibling; the failed
#      instance is NOT marked globally unavailable (only request-local exclusion).
RSpec.describe Legion::LLM::Inference::Executor, 'escalation circuit guard', :ssot_v3 do
  let(:model) { 'circuit-test-model' }

  # Build a request + Router pair for the shared model name.
  def build_engine_setup(routing_seed: 'ab' * 16)
    request = Legion::LLM::Inference::Request.build_for_test(
      routing_seed: routing_seed,
      messages:     [{ role: :user, content: 'hello' }],
      routing:      { model: model }
    )
    router = Legion::LLM::Router.new(request: request, operation: :chat, body_model: model)
    [request, router]
  end

  # Activate a chat instance in the Phase 1 Registry with the shared model.
  def activate_chat(provider_family:, instance_id:)
    activate(provider_family: provider_family, instance_id: instance_id,
             drafts: [offering_draft(model: model, supported: %i[chat], context: 200_000)])
  end

  # Mark an exact instance unavailable via the Phase 1 dispatch path
  # (equivalent to "trip the circuit" in the legacy health_tracker model).
  def mark_unavailable(provider_family:, instance_id:)
    key = instance_key(provider_family: provider_family, instance_id: instance_id)
    snap = snapshot
    inst = snap.instance(instance_key: key)
    Legion::Extensions::Llm::Inventory::Registry.dispatch_instance_unavailable(
      instance_key: key, publisher_token_id: inst.publisher_token_id,
      reason: 'test: dispatch unavailable'
    )
  end

  # Run the provider-call engine for an executor with a pre-built Router.
  # Yields the executor before dispatch so the caller can stub execute_provider_request.
  def run_engine(request, router, &setup_executor)
    executor = described_class.new(request)
    executor.instance_variable_set(:@router, router)
    setup_executor&.call(executor)
    executor.send(:run_provider_call_engine)
    executor
  end

  describe 'skipping unavailable instances (was: open circuit)' do
    it 'skips an unavailable instance and routes to the next eligible lane' do
      activate_chat(provider_family: 'vllm', instance_id: 'h200')
      activate_chat(provider_family: 'bedrock', instance_id: 'primary')

      # Mark vllm/h200 as unavailable — equivalent to "open circuit" in the old model.
      mark_unavailable(provider_family: 'vllm', instance_id: 'h200')

      request, router = build_engine_setup
      executor = run_engine(request, router) do |ex|
        allow(ex).to receive(:execute_provider_request)
      end

      expect(executor.instance_variable_get(:@resolved_provider)).to eq(:bedrock)
    end

    it 're-activating an unavailable instance allows it to be selected again' do
      # This is the probe-cleared recovery invariant: publish → unavailable → re-publish.
      activate_chat(provider_family: 'vllm', instance_id: 'primary')
      mark_unavailable(provider_family: 'vllm', instance_id: 'primary')

      # Without re-activation, the only available lane is gone → RoutingRejected.
      request1, router1 = build_engine_setup(routing_seed: 'aa' * 16)
      expect do
        run_engine(request1, router1) { |ex| allow(ex).to receive(:execute_provider_request) }
      end.to raise_error(Legion::LLM::Errors::RoutingRejected)

      # Re-activate (simulate probe success republishing the instance snapshot).
      activate_chat(provider_family: 'vllm', instance_id: 'primary')

      # After re-activation the instance must be selectable again.
      request2, router2 = build_engine_setup(routing_seed: 'bb' * 16)
      executor = run_engine(request2, router2) do |ex|
        allow(ex).to receive(:execute_provider_request)
      end
      expect(executor.instance_variable_get(:@resolved_provider)).to eq(:vllm)
    end

    it 'raises RoutingRejected when all instances are unavailable (no eligible lanes)' do
      activate_chat(provider_family: 'vllm', instance_id: 'h200')
      activate_chat(provider_family: 'bedrock', instance_id: 'primary')
      activate_chat(provider_family: 'anthropic', instance_id: 'primary')

      # Capture snapshot once so all token_ids are read before any mark changes state.
      ready_snap = snapshot
      %w[vllm bedrock anthropic].each do |pf|
        key = instance_key(provider_family: pf, instance_id: 'primary')
        # vllm uses 'h200', others use 'primary'
        key = instance_key(provider_family: 'vllm', instance_id: 'h200') if pf == 'vllm'
        inst = ready_snap.instance(instance_key: key)
        Legion::Extensions::Llm::Inventory::Registry.dispatch_instance_unavailable(
          instance_key: key, publisher_token_id: inst.publisher_token_id,
          reason: 'test: all unavailable'
        )
      end

      request, router = build_engine_setup
      expect do
        run_engine(request, router) { |ex| allow(ex).to receive(:execute_provider_request) }
      end.to raise_error(Legion::LLM::Errors::RoutingRejected)
    end

    it 'raises RoutingRejected when the registry is empty (no instances published)' do
      # Registry.reset! is called by :ssot_v3 before hook — no instances activated here.
      request, router = build_engine_setup
      expect do
        run_engine(request, router) { |ex| allow(ex).to receive(:execute_provider_request) }
      end.to raise_error(Legion::LLM::Errors::RoutingRejected)
    end
  end

  describe 'failing over across instances of the same provider' do
    it 'tries a sibling instance after an account-scoped (credit) error on the first attempt' do
      activate(provider_family: 'anthropic', instance_id: 'primary',
               drafts: [offering_draft(model: model, supported: %i[chat], context: 200_000)],
               sequence: 0)
      activate(provider_family: 'anthropic', instance_id: 'secondary',
               drafts: [offering_draft(model: model, supported: %i[chat], context: 200_000)],
               sequence: 0)

      request, router = build_engine_setup
      call_count = 0
      first_instance = nil
      executor = run_engine(request, router) do |ex|
        allow(ex).to receive(:execute_provider_request) do
          call_count += 1
          if call_count == 1
            first_instance = ex.instance_variable_get(:@resolved_instance)
            raise Legion::LLM::ProviderError, 'Your credit balance is too low to access the Anthropic API'
          end
          # second call: succeeds
        end
      end

      # Two dispatch attempts were made (failover happened).
      expect(call_count).to eq(2)
      # The second attempt landed on a different instance than the first.
      final_instance = executor.instance_variable_get(:@resolved_instance)
      expect(executor.instance_variable_get(:@resolved_provider)).to eq(:anthropic)
      expect(final_instance).not_to eq(first_instance)
      expect(%i[primary secondary]).to include(final_instance)
    end

    it 'does not globally mark either instance unavailable after a credit error (request-local exclusion only)' do
      activate(provider_family: 'anthropic', instance_id: 'primary',
               drafts: [offering_draft(model: model, supported: %i[chat], context: 200_000)],
               sequence: 0)
      activate(provider_family: 'anthropic', instance_id: 'secondary',
               drafts: [offering_draft(model: model, supported: %i[chat], context: 200_000)],
               sequence: 0)

      request, router = build_engine_setup
      call_count = 0
      run_engine(request, router) do |ex|
        allow(ex).to receive(:execute_provider_request) do
          call_count += 1
          raise Legion::LLM::ProviderError, 'credit balance too low' if call_count == 1
        end
      end

      # Both instances remain available in the Phase 1 Registry after the run.
      # Only the first-attempt target was excluded request-locally (consumed-target exclusion).
      post_run_snap = snapshot
      %w[primary secondary].each do |instance_id|
        key = instance_key(provider_family: 'anthropic', instance_id: instance_id)
        inst = post_run_snap.instance(instance_key: key)
        expect(inst).not_to be_nil
        expect(inst.availability.state).to eq(:available),
                                           "expected #{instance_id} to remain available but availability.state was #{inst.availability.state}"
      end
    end
  end
end
