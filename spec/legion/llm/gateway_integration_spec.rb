# frozen_string_literal: true

require 'spec_helper'

RSpec.describe 'Legion::LLM gateway teardown' do
  it 'does not attempt to load lex-llm-gateway' do
    # The begin/rescue LoadError block should be removed
    expect(defined?(Legion::Extensions::LLM::Gateway)).to be_nil
  end

  it 'chat routes directly without gateway check' do
    Legion::Settings[:llm][:default_provider] = :anthropic
    Legion::Settings[:llm][:default_model] = 'claude-opus-4-6'

    mock_session = double('session', with_tool: nil, model: 'claude-opus-4-6')
    allow(RubyLLM).to receive(:chat).and_return(mock_session)
    mock_response = double('response', content: 'direct', input_tokens: 5, output_tokens: 3)
    allow(mock_session).to receive(:ask).and_return(mock_response)

    result = Legion::LLM.chat(message: 'test')
    expect(result).not_to be_nil
  end

  it 'embed routes directly without gateway check' do
    require 'legion/llm/call/embeddings'
    allow(Legion::LLM::Embeddings).to receive(:generate).and_return({ vector: [0.1] })
    result = Legion::LLM.embed('test text', model: 'text-embedding-3-small')
    expect(result).to eq({ vector: [0.1] })
  end
end
