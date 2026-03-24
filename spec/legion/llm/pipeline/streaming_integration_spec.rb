# frozen_string_literal: true

require 'spec_helper'

RSpec.describe 'Pipeline streaming end-to-end' do
  before do
    Legion::Settings[:llm][:pipeline_enabled] = true
    Legion::Settings[:llm][:default_provider] = :anthropic
    Legion::Settings[:llm][:default_model] = 'claude-opus-4-6'
    Legion::LLM::ConversationStore.reset!
  end

  it 'streams chunks and persists conversation when conversation_id is set' do
    mock_session = double('session', with_tool: nil)
    allow(RubyLLM).to receive(:chat).and_return(mock_session)
    mock_response = double('response', content: 'full response', input_tokens: 10, output_tokens: 8, tool_calls: nil)
    allow(mock_response).to receive(:respond_to?).with(:content).and_return(true)
    allow(mock_response).to receive(:respond_to?).with(:input_tokens).and_return(true)
    allow(mock_response).to receive(:respond_to?).with(:output_tokens).and_return(true)
    allow(mock_response).to receive(:respond_to?).with(:model_id).and_return(false)
    allow(mock_response).to receive(:respond_to?).with(:tool_calls).and_return(false)
    allow(mock_session).to receive(:ask).and_yield('full ').and_yield('response').and_return(mock_response)

    chunks = []
    result = Legion::LLM.chat(
      message:         'test streaming',
      conversation_id: 'conv_stream_test'
    ) { |chunk| chunks << chunk }

    expect(chunks).to eq(['full ', 'response'])
    expect(result).to be_a(Legion::LLM::Pipeline::Response)

    stored = Legion::LLM::ConversationStore.messages('conv_stream_test')
    expect(stored.size).to eq(2)
    expect(stored.last[:content]).to eq('full response')
  end

  it 'context_store fires after stream completes, not during' do
    mock_session = double('session', with_tool: nil)
    allow(RubyLLM).to receive(:chat).and_return(mock_session)

    store_called_during_stream = false
    allow(Legion::LLM::ConversationStore).to receive(:append).and_wrap_original do |original, *args, **kwargs|
      store_called_during_stream = true if Thread.current[:streaming]
      original.call(*args, **kwargs)
    end

    mock_response = double('response', content: 'done', input_tokens: 5, output_tokens: 3, tool_calls: nil)
    allow(mock_response).to receive(:respond_to?).and_return(true)
    allow(mock_response).to receive(:respond_to?).with(:tool_calls).and_return(false)
    allow(mock_session).to receive(:ask) do |_msg, &blk|
      Thread.current[:streaming] = true
      blk&.call('done')
      Thread.current[:streaming] = false
      mock_response
    end

    Legion::LLM.chat(message: 'test', conversation_id: 'conv_order') { |_chunk| nil }

    expect(store_called_during_stream).to be false
  end
end
