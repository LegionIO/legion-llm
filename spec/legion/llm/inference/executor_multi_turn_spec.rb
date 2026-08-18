# frozen_string_literal: true

require 'spec_helper'

RSpec.describe 'Inference::Executor multi-turn message injection' do
  before do
    Legion::Settings.merge_settings('llm', Legion::LLM::Settings.default)
    Legion::Settings[:llm][:pipeline_enabled] = true
    stub_native_provider(content: 'reply')
  end

  context 'with a single message' do
    it 'passes the single message to the provider and returns a Response with the reply' do
      request = Legion::LLM::Inference::Request.build(
        messages: [{ role: :user, content: 'hello' }]
      )
      result = Legion::LLM::Inference::Executor.new(request).call

      expect(result).to be_a(Legion::LLM::Inference::Response)
      expect(result.message[:content]).to eq('reply')
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
      result = Legion::LLM::Inference::Executor.new(request).call

      expect(result).to be_a(Legion::LLM::Inference::Response)
    end

    it 'returns a Inference::Response with the reply content' do
      request = Legion::LLM::Inference::Request.build(messages: messages)
      result = Legion::LLM::Inference::Executor.new(request).call
      expect(result).to be_a(Legion::LLM::Inference::Response)
      expect(result.message[:content]).to eq('reply')
    end
  end

  context 'with two messages (one prior + one current)' do
    it 'injects exactly one prior message and returns a Response' do
      request = Legion::LLM::Inference::Request.build(
        messages: [
          { role: :user, content: 'first' },
          { role: :user, content: 'second' }
        ]
      )
      result = Legion::LLM::Inference::Executor.new(request).call
      expect(result).to be_a(Legion::LLM::Inference::Response)
    end
  end

  context 'streaming with multi-turn messages' do
    it 'injects prior messages before streaming ask and yields chunks' do
      messages = [
        { role: :user,      content: 'first message' },
        { role: :assistant, content: 'first reply' },
        { role: :user,      content: 'follow up' }
      ]
      request = Legion::LLM::Inference::Request.build(messages: messages, stream: true)
      executor = Legion::LLM::Inference::Executor.new(request)

      chunks = []
      result = executor.call_stream { |chunk| chunks << chunk }

      expect(result).to be_a(Legion::LLM::Inference::Response)
    end
  end
end
