# frozen_string_literal: true

require 'spec_helper'

RSpec.describe 'Legion::LLM backward compatibility via Prompt' do
  let(:mock_response) do
    double('Response', content: 'compat response', input_tokens: 10, output_tokens: 5,
                       tool_calls: nil, stop_reason: :end_turn, model_id: 'test-model')
  end

  let(:mock_session) do
    session = double('Chat')
    allow(session).to receive(:ask).and_return(mock_response)
    allow(session).to receive(:with_tool)
    allow(session).to receive(:with_instructions)
    allow(session).to receive(:add_message)
    allow(session).to receive(:respond_to?).and_return(false)
    allow(session).to receive(:respond_to?).with(:on_tool_call).and_return(false)
    allow(session).to receive(:respond_to?).with(:on_tool_result).and_return(false)
    session
  end

  before do
    Legion::Settings.reset!
    Legion::Settings.merge_settings('llm', Legion::LLM::Settings.default)
    Legion::Settings[:llm][:default_provider] = :anthropic
    Legion::Settings[:llm][:default_model] = 'claude-sonnet-4-6'
    Legion::Settings[:llm][:pipeline_enabled] = true
    allow(RubyLLM).to receive(:chat).and_return(mock_session)
  end

  describe 'Legion::LLM.chat delegates to Prompt.dispatch' do
    it 'routes through Prompt.dispatch when pipeline_enabled and not streaming' do
      expect(Legion::LLM::Prompt).to receive(:dispatch).and_call_original
      Legion::LLM.chat(message: 'Hello from .chat')
    end

    it 'returns a Inference::Response' do
      result = Legion::LLM.chat(message: 'Hello from .chat')
      expect(result).to be_a(Legion::LLM::Inference::Response)
    end
  end
end
