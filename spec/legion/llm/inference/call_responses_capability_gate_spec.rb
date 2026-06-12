# frozen_string_literal: true

require 'spec_helper'
require 'legion/llm/inference/executor'

# Regression: Executor#call_responses dispatched with capability: :responses
# even when the resolved provider didn't support it, raising ProviderError
# "unsupported capability :responses for provider <p>". The capability gate
# was checked BEFORE pre-provider routing, so a request that resolved to a
# non-responses provider after routing slipped through.
RSpec.describe 'Executor#call_responses capability gate' do
  let(:request) do
    # No explicit provider hint — auto-routing. This is the real-world
    # /v1/responses without X-Legion-Provider where routing picks vllm.
    Legion::LLM::Inference::Request.build(
      messages:        [{ role: 'user', content: 'hi' }],
      routing:         { model: 'qwen3.6-27b' },
      conversation_id: 'conv_test',
      stream:          false,
      caller:          { source: 'test' }
    )
  end

  let(:executor) { Legion::LLM::Inference::Executor.new(request) }

  let(:non_responses_adapter) do
    # Mirrors LexLLMAdapter#supports?: true for everything except :responses.
    instance_double(Legion::LLM::Call::LexLLMAdapter).tap do |adapter|
      allow(adapter).to receive(:supports?) { |cap| cap.to_sym != :responses }
    end
  end

  context 'when routing resolves to a non-responses provider AFTER the gate check' do
    before do
      # Simulate the routing step setting @resolved_provider = :vllm. This
      # mirrors what happens when X-Legion-Provider: vllm or auto-routing
      # picks vllm — the lex-llm adapter for vllm reports supports?(:responses)
      # == false, and Call::Dispatch.call(capability: :responses) raises
      # ProviderError "unsupported capability :responses for provider vllm".
      allow(Legion::LLM::Call::Registry).to receive(:registered?).and_return(true)
      allow(Legion::LLM::Call::Registry).to receive(:for).and_return(non_responses_adapter)
    end

    it 'falls back to call instead of raising' do
      fake_response = double('Inference::Response')
      allow(executor).to receive(:call).and_return(fake_response)
      allow(executor).to receive(:call_stream).and_return(fake_response)

      expect { executor.call_responses(body: { input: 'hi' }, stream: false) }.not_to raise_error
      expect(executor).to have_received(:call)
      expect(executor).not_to have_received(:call_stream)
    end

    it 'falls back to call_stream for streaming requests' do
      fake_response = double('Inference::Response')
      allow(executor).to receive(:call_stream).and_return(fake_response)
      allow(executor).to receive(:call).and_return(fake_response)

      expect { executor.call_responses(body: { input: 'hi' }, stream: true) { |_chunk| nil } }.not_to raise_error
      expect(executor).to have_received(:call_stream)
    end
  end

  context 'when @resolved_provider is set to a non-responses provider POST-routing' do
    # The bug: provider_supports_responses? is evaluated BEFORE
    # execute_pre_provider_steps runs. If routing then selects a different
    # provider than the request hint suggested (e.g. failover, escalation,
    # health-tracker rerouting), the dispatch happens with the post-routing
    # @resolved_provider but the gate already returned true.
    let(:request) do
      Legion::LLM::Inference::Request.build(
        messages:        [{ role: 'user', content: 'hi' }],
        routing:         { provider: :openai, model: 'gpt-5.4' }, # responses-capable hint
        conversation_id: 'conv_test',
        stream:          false,
        caller:          { source: 'test' }
      )
    end

    before do
      # Pre-gate: provider_supports_responses? must return true for the
      # initial hint.
      responses_adapter = instance_double(Legion::LLM::Call::LexLLMAdapter)
      allow(responses_adapter).to receive(:supports?).with(:responses).and_return(true)
      allow(Legion::LLM::Call::Registry).to receive(:registered?).and_return(true)
      allow(Legion::LLM::Call::Registry).to receive(:for) do |provider, **|
        if provider == :vllm
          non_responses_adapter
        else
          responses_adapter
        end
      end
    end

    it 're-checks capability AFTER routing resolves the actual provider, and falls back to chat' do
      # Simulate: pre-provider steps land on vllm (post-gate routing flip).
      allow(executor).to receive(:execute_pre_provider_steps) do
        executor.instance_variable_set(:@resolved_provider, :vllm)
        executor.instance_variable_set(:@resolved_instance, :default)
        executor.instance_variable_set(:@resolved_model, 'qwen3.6-27b')
      end
      allow(executor).to receive(:execute_provider_request_responses)
      allow(executor).to receive(:execute_provider_request)
      allow(executor).to receive(:execute_provider_request_stream)
      allow(executor).to receive(:execute_post_provider_steps)
      allow(executor).to receive(:build_response).and_return(double('Inference::Response'))

      expect { executor.call_responses(body: { input: 'hi' }, stream: false) }.not_to raise_error
      expect(executor).not_to have_received(:execute_provider_request_responses)
    end
  end
end
