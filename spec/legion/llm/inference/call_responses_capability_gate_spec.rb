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

  let(:responses_adapter) do
    instance_double(Legion::LLM::Call::LexLLMAdapter).tap do |adapter|
      allow(adapter).to receive(:supports?).with(:responses).and_return(true)
    end
  end

  context 'when the request has an explicit non-responses provider hint' do
    let(:request) do
      Legion::LLM::Inference::Request.build(
        messages:        [{ role: 'user', content: 'hi' }],
        routing:         { provider: :vllm, model: 'qwen3.6-27b' },
        conversation_id: 'conv_test',
        stream:          false,
        caller:          { source: 'test' }
      )
    end

    before do
      Legion::Settings[:llm][:routing][:escalation][:enabled] = false
      allow(Legion::LLM::Call::Registry).to receive(:registered?).and_return(true)
      allow(Legion::LLM::Call::Registry).to receive(:for).and_return(non_responses_adapter)
      allow(executor).to receive(:execute_pre_provider_steps) do
        executor.instance_variable_set(:@resolved_provider, :vllm)
        executor.instance_variable_set(:@resolved_instance, :default)
        executor.instance_variable_set(:@resolved_model, 'qwen3.6-27b')
      end
    end

    it 'routes first, then falls back to provider call instead of raising' do
      fake_response = double('Inference::Response')
      allow(executor).to receive(:execute_provider_request).and_return(fake_response)
      allow(executor).to receive(:execute_post_provider_steps)
      allow(executor).to receive(:build_response).and_return(fake_response)

      expect { executor.call_responses(body: { input: 'hi' }, stream: false) }.not_to raise_error
      expect(executor).to have_received(:execute_pre_provider_steps)
      expect(executor).to have_received(:execute_provider_request)
    end

    it 'routes first, then falls back to stream provider call for streaming requests' do
      fake_response = double('Inference::Response')
      allow(executor).to receive(:execute_provider_request_stream).and_return(fake_response)
      allow(executor).to receive(:execute_post_provider_steps)
      allow(executor).to receive(:build_response).and_return(fake_response)

      expect { executor.call_responses(body: { input: 'hi' }, stream: true) { |_chunk| nil } }.not_to raise_error
      expect(executor).to have_received(:execute_pre_provider_steps)
      expect(executor).to have_received(:execute_provider_request_stream)
    end
  end

  context 'when the request has no provider hint and routing later selects OpenAI' do
    before do
      Legion::Settings[:llm][:routing][:escalation][:enabled] = false
      allow(Legion::LLM::Call::Registry).to receive(:registered?).and_return(true)
      allow(Legion::LLM::Call::Registry).to receive(:for).and_return(responses_adapter)
    end

    it 'routes before deciding and uses upstream Responses for streaming OpenAI requests' do
      allow(executor).to receive(:execute_pre_provider_steps) do
        executor.instance_variable_set(:@resolved_provider, :openai)
        executor.instance_variable_set(:@resolved_instance, :env)
        executor.instance_variable_set(:@resolved_model, 'gpt-5.4-mini')
      end
      allow(executor).to receive(:execute_provider_request_responses)
      allow(executor).to receive(:execute_provider_request_stream)
      allow(executor).to receive(:execute_post_provider_steps)
      allow(executor).to receive(:build_response).and_return(double('Inference::Response'))

      expect { executor.call_responses(body: { input: 'hi' }, stream: true) { |_chunk| nil } }.not_to raise_error
      expect(executor).to have_received(:execute_provider_request_responses).with(body: { input: 'hi' }, stream: true)
      expect(executor).not_to have_received(:execute_provider_request_stream)
    end
  end

  context 'when escalation is enabled and routing selects OpenAI' do
    before do
      Legion::Settings[:llm][:routing][:escalation][:enabled] = true
      Legion::Settings[:llm][:routing][:escalation][:pipeline_enabled] = true
      allow(Legion::LLM::Call::Registry).to receive(:registered?).and_return(true)
      allow(Legion::LLM::Call::Registry).to receive(:for).and_return(responses_adapter)
    end

    it 'routes first, then sends the primary OpenAI attempt through upstream Responses' do
      resolution = Legion::LLM::Router::Resolution.new(
        tier: :frontier, provider: :openai, instance: :env, model: 'gpt-5.4-mini'
      )
      chain = Legion::LLM::Router::EscalationChain.new(resolutions: [resolution], max_attempts: 1)

      # P5: write openai/env/gpt-5.4-mini lane so select_next_lane finds it in the new loop
      write_test_lane(provider: :openai, instance: :env, model: 'gpt-5.4-mini', tier: :frontier)

      allow(executor).to receive(:execute_pre_provider_steps) do
        executor.instance_variable_set(:@resolved_provider, :openai)
        executor.instance_variable_set(:@resolved_instance, :env)
        executor.instance_variable_set(:@resolved_model, 'gpt-5.4-mini')
      end
      allow(executor).to receive(:build_default_escalation_chain).and_return(chain)
      allow(executor).to receive(:execute_provider_request_responses)
      allow(executor).to receive(:execute_provider_request_stream)
      allow(executor).to receive(:execute_post_provider_steps)
      allow(executor).to receive(:build_response).and_return(double('Inference::Response'))
      allow(executor).to receive(:emit_escalation_attempt_metering)
      allow(executor).to receive(:emit_escalation_attempt_audit)

      expect { executor.call_responses(body: { input: 'hi' }, stream: true) { |_chunk| nil } }.not_to raise_error
      expect(executor).to have_received(:execute_pre_provider_steps)
      expect(executor).to have_received(:execute_provider_request_responses).with(body: { input: 'hi' }, stream: true)
      expect(executor).not_to have_received(:execute_provider_request_stream)
    end
  end

  context 'when @resolved_provider is set to a non-responses provider POST-routing' do
    # The bug: a provider capability decision made before
    # execute_pre_provider_steps can disagree with the provider routing
    # actually selected.
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
      Legion::Settings[:llm][:routing][:escalation][:enabled] = false
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
