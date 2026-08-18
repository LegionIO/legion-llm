# frozen_string_literal: true

require 'spec_helper'
require 'legion/llm/inference/executor'

# N×N regression spec: Executor#call_responses delegates to the canonical
# execution path (step_provider_call / step_provider_call_stream).
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
  let(:fake_response) { double('Inference::Response') }

  # SSOT v3: mock at step_provider_call / step_provider_call_stream — the
  # canonical seam below execute_pre_provider_steps. Mocking execute_pre_provider_steps
  # alone leaves @routing_requirements nil, which causes RoutingSession to blow
  # up on maximum_attempts. Asserting at the step_* level is the correct SSOT v3
  # boundary: it tests that call_responses routes to the right canonical path
  # without needing the full routing-session machinery.
  context 'non-streaming' do
    before do
      allow(executor).to receive(:execute_pre_provider_steps)
      allow(executor).to receive(:execute_post_provider_steps)
      allow(executor).to receive(:build_response).and_return(fake_response)
    end

    it 'delegates to step_provider_call for the canonical execution path' do
      expect(executor).to receive(:step_provider_call).and_return(nil)
      expect { executor.call_responses(body: { input: 'hi' }, stream: false) }.not_to raise_error
    end
  end

  context 'streaming' do
    before do
      allow(executor).to receive(:execute_pre_provider_steps)
      allow(executor).to receive(:execute_post_provider_steps)
      allow(executor).to receive(:build_response).and_return(fake_response)
    end

    it 'delegates to step_provider_call_stream for the canonical execution path' do
      expect(executor).to receive(:step_provider_call_stream).and_return(nil)
      expect { executor.call_responses(body: { input: 'hi' }, stream: true) { |_chunk| nil } }.not_to raise_error
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
