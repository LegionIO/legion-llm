# frozen_string_literal: true

require 'spec_helper'

RSpec.describe 'Pipeline integration with Legion::LLM.chat' do
  before do
    Legion::Settings.merge_settings('llm', Legion::LLM::Settings.default)
    Legion::Settings[:llm][:pipeline_enabled] = true
    Legion::Settings[:llm][:default_model] = 'test-model'
    Legion::Settings[:llm][:default_provider] = :test
    allow(Legion::LLM).to receive(:started?).and_return(true)
  end

  it 'returns a Inference::Response when pipeline is enabled' do
    mock_session = double('RubyLLM::Chat')
    mock_response = double('RubyLLM::Message',
                           content:       'hello from pipeline',
                           role:          'assistant',
                           input_tokens:  10,
                           output_tokens: 5,
                           model_id:      'test-model')
    allow(RubyLLM).to receive(:chat).and_return(mock_session)
    allow(mock_session).to receive(:ask).and_return(mock_response)
    allow(mock_session).to receive(:with_tool).and_return(mock_session)

    result = Legion::LLM.chat(message: 'hello')
    expect(result).to be_a(Legion::LLM::Inference::Response)
    expect(result.message[:content]).to eq('hello from pipeline')
    expect(result.tracing).to be_a(Hash)
    expect(result.timeline).not_to be_empty
  end

  describe 'streaming via pipeline' do
    it 'uses call_stream when block is given' do
      mock_session = double('session', with_tool: nil)
      allow(RubyLLM).to receive(:chat).and_return(mock_session)
      mock_response = double('response', content: 'streamed', input_tokens: 5, output_tokens: 3)
      allow(mock_session).to receive(:ask).and_yield('stre').and_yield('amed').and_return(mock_response)

      chunks = []
      result = Legion::LLM.chat(message: 'hello') { |chunk| chunks << chunk }

      expect(chunks).to eq(%w[stre amed])
      expect(result).to be_a(Legion::LLM::Inference::Response)
    end
  end

  it 'falls back to legacy path when pipeline is disabled' do
    Legion::Settings[:llm][:pipeline_enabled] = false
    mock_session = double('RubyLLM::Chat')
    mock_response = double('RubyLLM::Message',
                           content: 'hello from legacy', role: 'assistant',
                           input_tokens: 10, output_tokens: 5, model_id: 'test-model')
    allow(RubyLLM).to receive(:chat).and_return(mock_session)
    allow(mock_session).to receive(:ask).and_return(mock_response)
    allow(mock_session).to receive(:with_tool).and_return(mock_session)
    allow(mock_session).to receive(:with_instructions).and_return(mock_session)

    result = Legion::LLM.chat(message: 'hello')
    expect(result).not_to be_a(Legion::LLM::Inference::Response)
  end
end
