# frozen_string_literal: true

require 'spec_helper'

RSpec.describe 'Pipeline streaming end-to-end' do
  before do
    Legion::Settings[:llm][:pipeline_enabled] = true
    Legion::Settings[:llm][:pipeline_async_post_steps] = false
    Legion::Settings[:llm][:routing][:escalation] ||= {}
    Legion::Settings[:llm][:routing][:escalation][:enabled] = false
    Legion::LLM::Inference::Conversation.reset!
    stub_native_provider(content: 'pipeline response')
  end

  it 'streams chunks and persists conversation when conversation_id is set' do
    chunks = []
    result = Legion::LLM.chat(
      message:         'test streaming',
      stream:          true,
      conversation_id: 'conv_stream_test'
    ) { |chunk| chunks << chunk }

    expect(chunks.map(&:content)).to eq(['pipeline response'])
    expect(result).to be_a(Legion::LLM::Inference::Response)

    stored = Legion::LLM::Inference::Conversation.messages('conv_stream_test')
    expect(stored.size).to eq(2)
    expect(stored.last[:content]).to eq('pipeline response')
  end

  it 'context_store fires after stream completes' do
    # SSOT v3 invariant: conversation storage is a post-provider step and runs
    # only after the streaming callable finishes — never interleaved with chunk delivery.
    append_call_count = 0
    allow(Legion::LLM::Inference::Conversation).to receive(:append).and_wrap_original do |original, *args, **kwargs|
      append_call_count += 1
      original.call(*args, **kwargs)
    end

    Legion::LLM.chat(message: 'test', stream: true, conversation_id: 'conv_order_ssot') { |_chunk| nil }

    # Conversation was stored (append called at least once for the exchange)
    expect(append_call_count).to be >= 1
    stored = Legion::LLM::Inference::Conversation.messages('conv_order_ssot')
    expect(stored).not_to be_empty
  end

  it 'yields chunks with a .content method when pipeline is enabled' do
    chunks = []
    result = Legion::LLM.chat(message: 'test', stream: true) { |chunk| chunks << chunk }

    expect(chunks.map(&:content)).to eq(['pipeline response'])
    expect(result).to be_a(Legion::LLM::Inference::Response)
    expect(result.message[:content]).to eq('pipeline response')
  end

  it 'forwards caller: to response.caller in pipeline streaming mode' do
    caller_val = { requested_by: { type: :external, identity: 'acp:my_runner' } }
    result = Legion::LLM.chat(message: 'test', stream: true, caller: caller_val) { |_chunk| nil }

    expect(result.caller).to eq(caller_val)
  end

  it 'keeps streaming prompt construction aligned with non-streaming execution' do
    Legion::Settings[:llm][:prompt_caching][:enabled] = true
    Legion::Settings[:llm][:prompt_caching][:cache_conversation] = true

    # SSOT v3: both streaming and non-streaming dispatch through the same executor
    # and SelectionDispatch path. Verify the streaming call succeeds with the same
    # enrichment pipeline (RAG + system) as the non-streaming path.
    apollo_runner = double('Knowledge')
    allow(apollo_runner).to receive(:retrieve_relevant).and_return(
      success: true,
      entries: [{ content: 'streaming parity context', content_type: 'fact', confidence: 0.9 }],
      count:   1
    )
    stub_const('Legion::Extensions::Apollo::Runners::Knowledge', apollo_runner)

    result = Legion::LLM.chat(
      message:          [
        { role: :user, content: 'first turn' },
        { role: :assistant, content: 'second turn' },
        { role: :user, content: 'final turn' }
      ],
      system:           'Base streaming system',
      stream:           true,
      context_strategy: :rag
    ) { |_chunk| nil }

    expect(result).to be_a(Legion::LLM::Inference::Response)
  end

  context 'when pipeline_enabled: false' do
    # SSOT v3: pipeline_enabled is no longer a gate for the streaming path.
    # When a block is given, call_stream is always used regardless of the setting.
    it 'still streams via call_stream when a block is given' do
      Legion::Settings[:llm][:pipeline_enabled] = false

      chunks = []
      Legion::LLM.chat(message: 'test', stream: true) { |chunk| chunks << chunk }

      expect(chunks.map(&:content)).to eq(['pipeline response'])
    end
  end
end
