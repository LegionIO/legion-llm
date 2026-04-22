# frozen_string_literal: true

require 'spec_helper'

RSpec.describe Legion::LLM::Inference::Executor do
  let(:request_with_tools) do
    Legion::LLM::Inference::Request.build(
      messages: [{ role: :user, content: 'use a tool' }],
      tools:    [double('MyTool')],
      routing:  { provider: :anthropic, model: 'claude-opus-4-6' }
    )
  end

  let(:request_empty_tools) do
    Legion::LLM::Inference::Request.build(
      messages: [{ role: :user, content: 'no tools please' }],
      tools:    [],
      routing:  { provider: :anthropic, model: 'claude-opus-4-6' }
    )
  end

  let(:session) { double('session', with_tool: nil, add_message: nil, with_instructions: nil) }

  describe '#inject_ruby_llm_tools' do
    context 'when @request.tools is a non-empty array' do
      it 'calls inject_registry_tools to add registry tools' do
        executor = described_class.new(request_with_tools)
        allow(executor).to receive(:inject_registry_tools)
        executor.send(:inject_ruby_llm_tools, session)
        expect(executor).to have_received(:inject_registry_tools).with(session)
      end
    end

    context 'when @request.tools is an empty array []' do
      it 'does NOT call inject_registry_tools' do
        executor = described_class.new(request_empty_tools)
        allow(executor).to receive(:inject_registry_tools)
        executor.send(:inject_ruby_llm_tools, session)
        expect(executor).not_to have_received(:inject_registry_tools)
      end

      it 'does not inject any tools on the session' do
        executor = described_class.new(request_empty_tools)
        allow(executor).to receive(:inject_registry_tools)
        executor.send(:inject_ruby_llm_tools, session)
        expect(session).not_to have_received(:with_tool)
      end
    end

    context 'when @request.tools is a non-Array (nil via direct construction)' do
      it 'calls inject_registry_tools (non-Array does not trigger sentinel)' do
        executor = described_class.new(request_with_tools)
        # Simulate a request where tools is nil (e.g., via a subclass or future refactor)
        stub_req = double('request',
                          tools:  nil,
                          caller: nil,
                          id:     'req_test')
        executor.instance_variable_set(:@request, stub_req)
        allow(executor).to receive(:inject_registry_tools)
        executor.send(:inject_ruby_llm_tools, session)
        expect(executor).to have_received(:inject_registry_tools).with(session)
      end
    end
  end
end
