# frozen_string_literal: true

require 'spec_helper'

RSpec.describe 'Inference::Executor multi-turn message injection' do
  before do
    Legion::Settings.merge_settings('llm', Legion::LLM::Settings.default)
    Legion::Settings[:llm][:pipeline_enabled] = true
    Legion::Settings[:llm][:default_model] = 'test-model'
    Legion::Settings[:llm][:default_provider] = :test
    stub_native_provider(content: 'reply')
  end

  context 'with a single message' do
    it 'does not call add_message and calls ask with the message content' do
      request = Legion::LLM::Inference::Request.build(
        messages: [{ role: :user, content: 'hello' }]
      )
      executor = Legion::LLM::Inference::Executor.new(request)

      expect(Legion::LLM::Call::Dispatch).to receive(:dispatch_chat).with(hash_including(
                                                                            messages: [{ role: :user, content: 'hello' }]
                                                                          )).and_return(native_dispatch_result(content: 'reply'))

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
      request = Legion::LLM::Inference::Request.build(messages: messages)
      executor = Legion::LLM::Inference::Executor.new(request)

      expect(Legion::LLM::Call::Dispatch).to receive(:dispatch_chat)
        .and_return(native_dispatch_result(content: 'reply'))

      executor.call
    end

    it 'returns a Inference::Response with the reply content' do
      request = Legion::LLM::Inference::Request.build(messages: messages)
      result = Legion::LLM::Inference::Executor.new(request).call
      expect(result).to be_a(Legion::LLM::Inference::Response)
      expect(result.message[:content]).to eq('reply')
    end
  end

  context 'with two messages (one prior + one current)' do
    it 'injects exactly one prior message' do
      request = Legion::LLM::Inference::Request.build(
        messages: [
          { role: :user, content: 'first' },
          { role: :user, content: 'second' }
        ]
      )
      executor = Legion::LLM::Inference::Executor.new(request)
      expect(Legion::LLM::Call::Dispatch).to receive(:dispatch_chat)
        .and_return(native_dispatch_result(content: 'reply'))

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
      request = Legion::LLM::Inference::Request.build(messages: messages)
      executor = Legion::LLM::Inference::Executor.new(request)

      expect(Legion::LLM::Call::Dispatch).to receive(:dispatch_stream)
        .and_return(native_dispatch_result(content: 'reply'))

      chunks = []
      executor.call_stream { |chunk| chunks << chunk }
    end
  end
end
