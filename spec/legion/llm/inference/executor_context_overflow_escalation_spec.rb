# frozen_string_literal: true

require 'spec_helper'
require 'legion/llm/router/request_requirements'
require 'legion/llm/inference/routing_session'

# Context overflow escalation — SSOT v3 rewrite.
#
# INVARIANT (survives): ContextOverflow is NOT a non_provider_failure — it is
# a provider-side signal that the payload was too large for THIS lane's context
# window. ssot_v3_execute_attempt converts it to a :provider_error ProviderOutcome
# (retryable), allowing the RoutingSession to retry on a different lane.
# Only when all attempts are exhausted does the RoutingSession raise RoutingRejected.
#
# What changed in SSOT v3: there are no "tried_lanes", no classify_and_accumulate_exclusions,
# and no Inventory.lanes scan to check context windows. The routing session simply
# retries the next eligible lane (consumed-target exclusion prevents reselecting
# the same overflowed lane).
RSpec.describe Legion::LLM::Inference::Executor, 'context overflow escalation' do
  let(:executor_class) { described_class }

  describe '#non_provider_failure? for ContextOverflow' do
    it 'returns false — context overflow is a provider-side signal, not a daemon error' do
      executor = executor_class.allocate
      err = Legion::LLM::ContextOverflow.new('vllm:gemma-4-31b-it — context too long')
      expect(executor.send(:non_provider_failure?, err)).to be false
    end
  end

  describe '#ssot_v3_execute_attempt with ContextOverflow' do
    it 'returns a failure SelectionDispatch::Result (not re-raise) so routing session can retry' do
      executor = executor_class.allocate
      err = Legion::LLM::ContextOverflow.new(
        "vllm:gemma-4-31b-it — This model's maximum context length is 262144 tokens. " \
        'However, you requested 0 output tokens and your prompt contains at least 262145 input tokens'
      )
      allow(executor).to receive(:execute_provider_request).and_raise(err)

      result = executor.send(:ssot_v3_execute_attempt)
      expect(result).to be_a(Legion::LLM::Call::SelectionDispatch::Result)
      expect(result.failure?).to be true
      # ContextOverflow maps to :provider_error (retryable) since it is not
      # a known Phase 1 outcome kind at the executor layer.
      expect(result.outcome.kind).to eq(:provider_error)
    end
  end

  describe 'RoutingSession retry after ContextOverflow', :ssot_v3 do
    let(:model) { 'gemma4-context-test' }

    def build_requirements
      request = Legion::LLM::Inference::Request.build_for_test(
        routing_seed: 'ab' * 16,
        messages:     [{ role: :user, content: 'hello' }],
        routing:      { model: model }
      )
      reqs = Legion::LLM::Router::RequestRequirements.build(
        request: request, operation: :chat, required_capabilities: [],
        estimated_input_bound: 10, required_output_tokens: 0
      )
      [request, reqs]
    end

    it 'retries the next eligible lane after a context overflow, succeeding on the second attempt' do
      # Two instances: primary (first selected) will overflow; secondary succeeds.
      activate(provider_family: 'vllm', instance_id: 'primary',
               drafts: [offering_draft(model: model, supported: %i[chat], context: 262_144)])
      activate(provider_family: 'vllm', instance_id: 'secondary',
               drafts: [offering_draft(model: model, supported: %i[chat], context: 1_048_576)])

      request, reqs = build_requirements
      executor = executor_class.new(request)
      executor.instance_variable_set(:@routing_requirements, reqs)

      call_count = 0
      allow(executor).to receive(:execute_provider_request) do
        call_count += 1
        raise Legion::LLM::ContextOverflow, 'context too long' if call_count == 1
        # second call succeeds
      end

      # Should NOT raise — the second lane succeeds
      expect { executor.send(:run_provider_call_engine) }.not_to raise_error
      expect(call_count).to eq(2)
    end

    it 'raises RoutingRejected (attempts exhausted) when every eligible lane overflows' do
      # Only one instance — after it overflows and the attempt is consumed,
      # there are no more eligible lanes.
      activate(provider_family: 'vllm', instance_id: 'only',
               drafts: [offering_draft(model: model, supported: %i[chat], context: 4096)])

      request, reqs = build_requirements
      executor = executor_class.new(request)
      executor.instance_variable_set(:@routing_requirements, reqs)

      allow(executor).to receive(:execute_provider_request).and_raise(
        Legion::LLM::ContextOverflow, 'context too long'
      )

      expect { executor.send(:run_provider_call_engine) }
        .to raise_error(Legion::LLM::Errors::RoutingRejected)
    end
  end
end
