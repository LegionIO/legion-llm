# frozen_string_literal: true

require 'spec_helper'

RSpec.describe Legion::LLM::Context::Compressor do
  describe '.estimate_tokens' do
    it 'returns 0 for nil messages' do
      expect(described_class.estimate_tokens(nil)).to eq(0)
    end

    it 'returns 0 for empty messages' do
      expect(described_class.estimate_tokens([])).to eq(0)
    end

    it 'estimates tokens as character count divided by 4' do
      messages = [
        { role: 'user', content: 'a' * 400 },
        { role: 'assistant', content: 'b' * 200 }
      ]
      expect(described_class.estimate_tokens(messages)).to eq(150)
    end

    it 'handles messages with nil content' do
      messages = [{ role: 'user', content: nil }]
      expect(described_class.estimate_tokens(messages)).to eq(0)
    end
  end

  describe '.auto_compact' do
    let(:older_messages) do
      15.times.map do |i|
        { role: i.even? ? 'user' : 'assistant', content: "Message number #{i} with some content." }
      end
    end

    let(:messages) { older_messages }

    context 'when message count is at or below preserve_recent' do
      it 'returns messages unchanged when count equals preserve_recent' do
        msgs = 10.times.map { |i| { role: 'user', content: "msg #{i}" } }
        result = described_class.auto_compact(msgs, target_tokens: 1000, preserve_recent: 10)
        expect(result).to eq(msgs)
      end

      it 'returns messages unchanged when count is below preserve_recent' do
        msgs = 5.times.map { |i| { role: 'user', content: "msg #{i}" } }
        result = described_class.auto_compact(msgs, target_tokens: 1000, preserve_recent: 10)
        expect(result).to eq(msgs)
      end
    end

    context 'when message count exceeds preserve_recent' do
      it 'preserves the most recent N messages' do
        result = described_class.auto_compact(messages, target_tokens: 1000, preserve_recent: 5)
        recent = messages.last(5)
        result_contents = result.map { |m| m[:content] }
        recent.each do |msg|
          expect(result_contents).to include(msg[:content])
        end
      end

      it 'produces fewer messages than the original' do
        result = described_class.auto_compact(messages, target_tokens: 1000, preserve_recent: 5)
        expect(result.size).to be < messages.size
      end

      it 'includes a compaction record as first message' do
        result = described_class.auto_compact(messages, target_tokens: 1000, preserve_recent: 5)
        first = result.first
        expect(first[:role]).to eq('system')
        expect(first[:content]).to include('Conversation compacted')
        expect(first[:content]).to include('summarized')
      end

      it 'includes metadata on the compaction record' do
        result = described_class.auto_compact(messages, target_tokens: 1000, preserve_recent: 5)
        metadata = result.first[:metadata]
        expect(metadata).to be_a(Hash)
        expect(metadata[:original_count]).to eq(messages.size)
        expect(metadata[:preserved]).to eq(5)
        expect(metadata[:compacted_at]).to be_a(String)
      end

      it 'includes a summary message after the compaction record' do
        result = described_class.auto_compact(messages, target_tokens: 1000, preserve_recent: 5)
        expect(result.size).to be >= 3
        expect(result[1][:role]).to eq('system')
      end

      it 'uses preserve_recent default of 10 when not specified' do
        msgs = 20.times.map { |i| { role: 'user', content: "message #{i}" } }
        result = described_class.auto_compact(msgs, target_tokens: 2000)
        recent = msgs.last(10)
        result_contents = result.map { |m| m[:content] }
        recent.each do |msg|
          expect(result_contents).to include(msg[:content])
        end
      end
    end

    context 'with LLM unavailable (stopword fallback)' do
      it 'still produces a compacted result via stopword compression' do
        result = described_class.auto_compact(messages, target_tokens: 1000, preserve_recent: 5)
        expect(result).to be_an(Array)
        expect(result).not_to be_empty
        first = result.first
        expect(first[:role]).to eq('system')
      end
    end
  end

  describe 'pipeline integration: auto-compact wiring' do
    before { Legion::LLM::Inference::Conversation.reset! }

    let(:conv_id) { 'conv_autocompact_test' }

    def build_long_history(token_count)
      # Each message has roughly token_count / msg_count chars * 4 chars/token
      msg_count = 20
      chars_per_msg = (token_count * 4) / msg_count
      msg_count.times.map do |i|
        Legion::LLM::Inference::Conversation.append(
          conv_id,
          role:    i.even? ? :user : :assistant,
          content: 'x' * chars_per_msg
        )
      end
    end

    it 'does not compact when below threshold' do
      build_long_history(1_000)

      Legion::Settings[:llm][:conversation] = {
        auto_compact:        true,
        summarize_threshold: 50_000,
        target_tokens:       20_000,
        preserve_recent:     10
      }

      req = Legion::LLM::Inference::Request.build(
        messages:        [{ role: :user, content: 'hello' }],
        conversation_id: conv_id
      )
      executor = Legion::LLM::Inference::Executor.new(req)
      allow(executor).to receive(:step_provider_call)
      executor.call

      # 20 original + 1 new user message appended by step_context_store
      history = Legion::LLM::Inference::Conversation.messages(conv_id)
      expect(history.size).to eq(21)
      expect(history.none? { |m| m[:content].to_s.include?('Conversation compacted') }).to be true
    end

    it 'compacts when above threshold' do
      build_long_history(60_000)

      Legion::Settings[:llm][:conversation] = {
        auto_compact:        true,
        summarize_threshold: 50_000,
        target_tokens:       20_000,
        preserve_recent:     5
      }

      req = Legion::LLM::Inference::Request.build(
        messages:        [{ role: :user, content: 'hello' }],
        conversation_id: conv_id
      )
      executor = Legion::LLM::Inference::Executor.new(req)
      allow(executor).to receive(:step_provider_call)
      executor.call

      # The history was compacted before enriching; verify the store was updated
      history = Legion::LLM::Inference::Conversation.messages(conv_id)
      expect(history.any? { |m| m[:content].to_s.include?('Conversation compacted') }).to be true
    end

    it 'does not compact when auto_compact is false' do
      build_long_history(60_000)

      Legion::Settings[:llm][:conversation] = {
        auto_compact:        false,
        summarize_threshold: 50_000,
        target_tokens:       20_000,
        preserve_recent:     5
      }

      req = Legion::LLM::Inference::Request.build(
        messages:        [{ role: :user, content: 'hello' }],
        conversation_id: conv_id
      )
      executor = Legion::LLM::Inference::Executor.new(req)
      allow(executor).to receive(:step_provider_call)
      executor.call

      # No compaction: 20 original + 1 new user message
      history = Legion::LLM::Inference::Conversation.messages(conv_id)
      expect(history.none? { |m| m[:content].to_s.include?('Conversation compacted') }).to be true
    end
  end
end
