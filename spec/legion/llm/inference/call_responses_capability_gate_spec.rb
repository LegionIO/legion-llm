# frozen_string_literal: true

require 'spec_helper'
require 'legion/llm/inference/executor'

# N×N regression spec: Executor#call_responses delegates to the canonical
# execution path (execute_provider_request / execute_provider_request_stream).
# The executor is blind to provider API formats; the API namespace translator
# converts Responses API format to canonical before the executor sees it.
# See CLAUDE.md §N×N: "the router/executor should not know the difference between
# what lex-llm-* calls what endpoint".
RSpec.describe 'Executor#call_responses delegates to canonical' do
  let(:request) do
    Legion::LLM::Inference::Request.build(
      messages:        [{ role: 'user', content: 'hi' }],
      routing:         { model: 'gpt-5.4-mini' },
      conversation_id: 'conv_test',
      stream:          false,
      caller:          { source: 'test' }
    )
  end

  let(:executor) { Legion::LLM::Inference::Executor.new(request) }

  context 'non-streaming' do
    before do
      Legion::Settings[:llm][:routing][:escalation][:enabled] = false
      allow(executor).to receive(:execute_pre_provider_steps) do
        executor.instance_variable_set(:@resolved_provider, :openai)
        executor.instance_variable_set(:@resolved_instance, :env)
        executor.instance_variable_set(:@resolved_model, 'gpt-5.4-mini')
      end
    end

    it 'delegates to execute_provider_request via step_provider_call' do
      fake_response = double('Inference::Response')
      allow(executor).to receive(:execute_provider_request).and_return(fake_response)
      allow(executor).to receive(:execute_post_provider_steps)
      allow(executor).to receive(:build_response).and_return(fake_response)

      expect { executor.call_responses(body: { input: 'hi' }, stream: false) }.not_to raise_error
      expect(executor).to have_received(:execute_provider_request)
    end
  end

  context 'streaming' do
    before do
      Legion::Settings[:llm][:routing][:escalation][:enabled] = false
      allow(executor).to receive(:execute_pre_provider_steps) do
        executor.instance_variable_set(:@resolved_provider, :openai)
        executor.instance_variable_set(:@resolved_instance, :env)
        executor.instance_variable_set(:@resolved_model, 'gpt-5.4-mini')
      end
    end

    it 'delegates to execute_provider_request_stream via step_provider_call_stream' do
      fake_response = double('Inference::Response')
      allow(executor).to receive(:execute_provider_request_stream).and_return(fake_response)
      allow(executor).to receive(:execute_post_provider_steps)
      allow(executor).to receive(:build_response).and_return(fake_response)

      expect { executor.call_responses(body: { input: 'hi' }, stream: true) { |_chunk| nil } }.not_to raise_error
      expect(executor).to have_received(:execute_provider_request_stream)
    end
  end

  context 'N×N law enforcement' do
    it 'no provider_supports_responses? method exists on executor (N×N: executor is format-agnostic)' do
      expect(executor).not_to respond_to(:provider_supports_responses?)
    end

    it 'no resolved_provider_supports_responses? method exists on executor (N×N: executor is format-agnostic)' do
      expect(executor).not_to respond_to(:resolved_provider_supports_responses?)
    end
  end
end
