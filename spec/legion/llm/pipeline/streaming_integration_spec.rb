# frozen_string_literal: true

require 'spec_helper'

RSpec.describe 'Pipeline streaming end-to-end' do
  before do
    Legion::Settings[:llm][:pipeline_enabled] = true
    Legion::Settings[:llm][:pipeline_async_post_steps] = false
    Legion::Settings[:llm][:default_provider] = :anthropic
    Legion::Settings[:llm][:default_model] = 'claude-opus-4-6'
    Legion::LLM::ConversationStore.reset!
  end

  it 'streams chunks and persists conversation when conversation_id is set' do
    mock_session = double('session', with_tool: nil)
    allow(RubyLLM).to receive(:chat).and_return(mock_session)
    mock_response = double('response', content: 'full response', input_tokens: 10, output_tokens: 8, cache_read_tokens: 0, cache_write_tokens: 0,
tool_calls: nil)
    allow(mock_response).to receive(:respond_to?).with(:content).and_return(true)
    allow(mock_response).to receive(:respond_to?).with(:input_tokens).and_return(true)
    allow(mock_response).to receive(:respond_to?).with(:output_tokens).and_return(true)
    allow(mock_response).to receive(:respond_to?).with(:cache_read_tokens).and_return(true)
    allow(mock_response).to receive(:respond_to?).with(:cache_write_tokens).and_return(true)
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

    mock_response = double('response', content: 'done', input_tokens: 5, output_tokens: 3, cache_read_tokens: 0, cache_write_tokens: 0, tool_calls: nil)
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

  it 'yields chunks with a .content method when pipeline is enabled' do
    chunk1 = double('chunk1', content: 'Hello ')
    chunk2 = double('chunk2', content: 'world')
    mock_session = double('session', with_tool: nil)
    allow(RubyLLM).to receive(:chat).and_return(mock_session)
    mock_response = double('response', content: 'Hello world', input_tokens: 10, output_tokens: 5, cache_read_tokens: 0, cache_write_tokens: 0, tool_calls: nil)
    allow(mock_response).to receive(:respond_to?).and_return(true)
    allow(mock_response).to receive(:respond_to?).with(:tool_calls).and_return(false)
    allow(mock_session).to receive(:ask).and_yield(chunk1).and_yield(chunk2).and_return(mock_response)

    chunks = []
    result = Legion::LLM.chat(message: 'test') { |chunk| chunks << chunk }

    expect(chunks.map(&:content)).to eq(['Hello ', 'world'])
    expect(result).to be_a(Legion::LLM::Pipeline::Response)
    expect(result.message[:content]).to eq('Hello world')
  end

  it 'forwards caller: to response.caller in pipeline streaming mode' do
    mock_session = double('session', with_tool: nil)
    allow(RubyLLM).to receive(:chat).and_return(mock_session)
    mock_response = double('response', content: 'ok', input_tokens: 3, output_tokens: 2, cache_read_tokens: 0, cache_write_tokens: 0, tool_calls: nil)
    allow(mock_response).to receive(:respond_to?).and_return(true)
    allow(mock_response).to receive(:respond_to?).with(:tool_calls).and_return(false)
    allow(mock_session).to receive(:ask).and_return(mock_response)

    caller_val = { requested_by: { type: :external, identity: 'acp:my_runner' } }
    result = Legion::LLM.chat(message: 'test', caller: caller_val) { |_chunk| nil }

    expect(result.caller).to eq(caller_val)
  end

  it 'keeps streaming prompt construction aligned with non-streaming execution' do
    Legion::Settings[:llm][:prompt_caching][:enabled] = true
    Legion::Settings[:llm][:prompt_caching][:cache_conversation] = true

    apollo_runner = double('Knowledge')
    allow(apollo_runner).to receive(:retrieve_relevant).and_return(
      success: true,
      entries: [{ content: 'streaming parity context', content_type: 'fact', confidence: 0.9 }],
      count:   1
    )
    stub_const('Legion::Extensions::Apollo::Runners::Knowledge', apollo_runner)

    mock_session = double('session')
    allow(RubyLLM).to receive(:chat).and_return(mock_session)
    allow(mock_session).to receive(:with_tool).and_return(mock_session)
    allow(mock_session).to receive(:with_instructions).and_return(mock_session)
    allow(mock_session).to receive(:add_message)

    mock_response = double('response', content: 'aligned', input_tokens: 9, output_tokens: 4, cache_read_tokens: 0, cache_write_tokens: 0,
tool_calls: nil)
    allow(mock_response).to receive(:respond_to?).and_return(true)
    allow(mock_response).to receive(:respond_to?).with(:tool_calls).and_return(false)
    allow(mock_session).to receive(:ask).and_return(mock_response)

    expect(mock_session).to receive(:with_instructions).with(
      a_string_including('Base streaming system', 'streaming parity context')
    ).and_return(mock_session)

    Legion::LLM.chat(
      message:          [
        { role: :user, content: 'first turn' },
        { role: :assistant, content: 'second turn' },
        { role: :user, content: 'final turn' }
      ],
      system:           'Base streaming system',
      context_strategy: :rag
    ) { |_chunk| nil }

    expect(mock_session).to have_received(:add_message).with(
      hash_including(role: :assistant, cache_control: { type: 'ephemeral' })
    )
  end

  context 'when pipeline_enabled: false' do
    before { Legion::Settings[:llm][:pipeline_enabled] = false }

    it 'streams chunks via direct path when a block is given' do
      chunk1 = double('chunk1', content: 'Hi ')
      chunk2 = double('chunk2', content: 'there')
      mock_session = double('session', with_tool: nil)
      allow(RubyLLM).to receive(:chat).and_return(mock_session)
      mock_response = double('response', content: 'Hi there', input_tokens: 5, output_tokens: 4)
      allow(mock_session).to receive(:ask).and_yield(chunk1).and_yield(chunk2).and_return(mock_response)

      chunks = []
      Legion::LLM.chat(message: 'test') { |chunk| chunks << chunk }

      expect(chunks.map(&:content)).to eq(['Hi ', 'there'])
    end
  end
end
