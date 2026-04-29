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
    mock_session = double('NativeChat')
    mock_response = double('ProviderMessage',
                           content:       'hello from pipeline',
                           role:          'assistant',
                           input_tokens:  10,
                           output_tokens: 5,
                           model_id:      'test-model')
    stub_native_provider(content: 'pipeline response')
    allow(mock_session).to receive(:ask).and_return(mock_response)
    allow(mock_session).to receive(:with_tool).and_return(mock_session)

    result = Legion::LLM.chat(message: 'hello')
    expect(result).to be_a(Legion::LLM::Inference::Response)
    expect(result.message[:content]).to eq('pipeline response')
    expect(result.tracing).to be_a(Hash)
    expect(result.timeline).not_to be_empty
  end

  it 'treats string-keyed pipeline_enabled as enabled' do
    allow(Legion::LLM).to receive(:settings).and_return({
                                                          'pipeline_enabled' => true,
                                                          'default_model'    => 'test-model',
                                                          'default_provider' => :test
                                                        })

    expect(Legion::LLM::Inference.pipeline_enabled?).to be(true)
  end

  describe 'streaming via pipeline' do
    it 'uses call_stream when block is given' do
      mock_session = double('session', with_tool: nil)
      stub_native_provider(content: 'pipeline response')
      mock_response = double('response', content: 'streamed', input_tokens: 5, output_tokens: 3)
      allow(mock_session).to receive(:ask).and_yield('stre').and_yield('amed').and_return(mock_response)

      chunks = []
      result = Legion::LLM.chat(message: 'hello') { |chunk| chunks << chunk }

      expect(chunks.map(&:content)).to eq(['pipeline response'])
      expect(result).to be_a(Legion::LLM::Inference::Response)
    end
  end

  it 'falls back to legacy path when pipeline is disabled' do
    Legion::Settings[:llm][:pipeline_enabled] = false
    mock_session = double('NativeChat')
    mock_response = double('ProviderMessage',
                           content: 'hello from legacy', role: 'assistant',
                           input_tokens: 10, output_tokens: 5, model_id: 'test-model')
    stub_native_provider(content: 'pipeline response')
    allow(mock_session).to receive(:ask).and_return(mock_response)
    allow(mock_session).to receive(:with_tool).and_return(mock_session)
    allow(mock_session).to receive(:with_instructions).and_return(mock_session)

    result = Legion::LLM.chat(message: 'hello')
    expect(result).not_to be_a(Legion::LLM::Inference::Response)
  end
end
