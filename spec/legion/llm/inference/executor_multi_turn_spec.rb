# frozen_string_literal: true

require 'spec_helper'

RSpec.describe 'Pipeline::Executor multi-turn message injection' do
  let(:mock_session) do
    dbl = double('RubyLLM::Chat')
    allow(dbl).to receive(:with_tool)
    allow(dbl).to receive(:with_instructions)
    allow(dbl).to receive(:add_message)
    dbl
  end

  let(:mock_response) do
    double('RubyLLM::Message',
           content:       'reply',
           role:          'assistant',
           input_tokens:  5,
           output_tokens: 3,
           model_id:      'test-model')
  end

  before do
    Legion::Settings.merge_settings('llm', Legion::LLM::Settings.default)
    Legion::Settings[:llm][:pipeline_enabled] = true
    Legion::Settings[:llm][:default_model] = 'test-model'
    Legion::Settings[:llm][:default_provider] = :test
    allow(RubyLLM).to receive(:chat).and_return(mock_session)
    allow(mock_session).to receive(:ask).and_return(mock_response)
  end

  context 'with a single message' do
    it 'does not call add_message and calls ask with the message content' do
      request = Legion::LLM::Pipeline::Request.build(
        messages: [{ role: :user, content: 'hello' }]
      )
      executor = Legion::LLM::Pipeline::Executor.new(request)

      expect(mock_session).not_to receive(:add_message)
      expect(mock_session).to receive(:ask).with('hello').and_return(mock_response)

      executor.call
    end
  end

  context 'with multiple messages (multi-turn conversation)' do
    let(:messages) do
      [
        { role: :user,      content: 'what is ruby?' },
        { role: :assistant, content: 'Ruby is a language.' },
        { role: :user,      content: 'tell me more' }
      ]
    end

    it 'injects prior messages via add_message before the final ask' do
      request = Legion::LLM::Pipeline::Request.build(messages: messages)
      executor = Legion::LLM::Pipeline::Executor.new(request)

      expect(mock_session).to receive(:add_message).with(hash_including(role: :user,      content: 'what is ruby?')).ordered
      expect(mock_session).to receive(:add_message).with(hash_including(role: :assistant, content: 'Ruby is a language.')).ordered
      expect(mock_session).to receive(:ask).with('tell me more').ordered.and_return(mock_response)

      executor.call
    end

    it 'returns a Pipeline::Response with the reply content' do
      request = Legion::LLM::Pipeline::Request.build(messages: messages)
      allow(mock_session).to receive(:add_message)
      result = Legion::LLM::Pipeline::Executor.new(request).call
      expect(result).to be_a(Legion::LLM::Pipeline::Response)
      expect(result.message[:content]).to eq('reply')
    end
  end

  context 'with two messages (one prior + one current)' do
    it 'injects exactly one prior message' do
      request = Legion::LLM::Pipeline::Request.build(
        messages: [
          { role: :user, content: 'first' },
          { role: :user, content: 'second' }
        ]
      )
      executor = Legion::LLM::Pipeline::Executor.new(request)

      expect(mock_session).to receive(:add_message).with(hash_including(role: :user, content: 'first')).once
      expect(mock_session).to receive(:ask).with('second').and_return(mock_response)

      executor.call
    end
  end

  context 'streaming with multi-turn messages' do
    it 'injects prior messages before streaming ask' do
      messages = [
        { role: :user,      content: 'first message' },
        { role: :assistant, content: 'first reply' },
        { role: :user,      content: 'follow up' }
      ]
      request = Legion::LLM::Pipeline::Request.build(messages: messages)
      executor = Legion::LLM::Pipeline::Executor.new(request)

      expect(mock_session).to receive(:add_message).with(hash_including(role: :user,      content: 'first message')).ordered
      expect(mock_session).to receive(:add_message).with(hash_including(role: :assistant, content: 'first reply')).ordered
      expect(mock_session).to receive(:ask).with('follow up').ordered.and_return(mock_response)

      chunks = []
      executor.call_stream { |chunk| chunks << chunk }
    end
  end
end
