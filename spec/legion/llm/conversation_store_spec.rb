# frozen_string_literal: true

require 'spec_helper'

RSpec.describe Legion::LLM::Inference::Conversation do
  before { described_class.reset! }

  describe '.append' do
    it 'stores a message for a conversation' do
      described_class.append('conv_1', role: :user, content: 'hello')
      messages = described_class.messages('conv_1')
      expect(messages.size).to eq(1)
      expect(messages.first[:role]).to eq(:user)
      expect(messages.first[:content]).to eq('hello')
    end

    it 'assigns sequential seq numbers' do
      described_class.append('conv_1', role: :user, content: 'hello')
      described_class.append('conv_1', role: :assistant, content: 'hi')
      messages = described_class.messages('conv_1')
      expect(messages.map { |m| m[:seq] }).to eq([1, 2])
    end

    it 'stores provider and token metadata' do
      described_class.append('conv_1',
                             role: :assistant, content: 'hi',
                             provider: :anthropic, model: 'claude-opus-4-6',
                             input_tokens: 10, output_tokens: 5)
      msg = described_class.messages('conv_1').first
      expect(msg[:provider]).to eq(:anthropic)
      expect(msg[:input_tokens]).to eq(10)
    end
  end

  describe '.messages' do
    it 'returns empty array for unknown conversation' do
      expect(described_class.messages('unknown')).to eq([])
    end

    it 'returns messages in seq order' do
      described_class.append('conv_1', role: :user, content: 'first')
      described_class.append('conv_1', role: :assistant, content: 'second')
      described_class.append('conv_1', role: :user, content: 'third')
      contents = described_class.messages('conv_1').map { |m| m[:content] }
      expect(contents).to eq(%w[first second third])
    end
  end

  describe '.create_conversation' do
    it 'registers a conversation with metadata' do
      described_class.create_conversation('conv_1', caller_identity: 'user:matt')
      expect(described_class.conversation_exists?('conv_1')).to be true
    end
  end

  describe '.read_sticky_state' do
    it 'returns a frozen empty hash when conversation is not in memory' do
      result = described_class.read_sticky_state('nonexistent-conv')
      expect(result).to eq({})
      expect(result).to be_frozen
    end

    it 'returns {} when conversation exists but has no sticky_state' do
      described_class.append('conv-sticky-1', role: :user, content: 'hello')
      result = described_class.read_sticky_state('conv-sticky-1')
      expect(result).to eq({})
    end

    it 'returns the stored sticky_state for an in-memory conversation' do
      described_class.append('conv-sticky-2', role: :user, content: 'hello')
      described_class.write_sticky_state('conv-sticky-2', { deferred_tool_calls: 3 })
      result = described_class.read_sticky_state('conv-sticky-2')
      expect(result[:deferred_tool_calls]).to eq(3)
    end
  end

  describe '.write_sticky_state' do
    it 'no-ops when conversation is not in memory' do
      expect { described_class.write_sticky_state('ghost-conv', { foo: 1 }) }.not_to raise_error
      expect(described_class.read_sticky_state('ghost-conv')).to eq({})
    end

    it 'persists state to an in-memory conversation' do
      described_class.append('conv-sticky-3', role: :user, content: 'hi')
      described_class.write_sticky_state('conv-sticky-3', { deferred_tool_calls: 7 })
      expect(described_class.read_sticky_state('conv-sticky-3')[:deferred_tool_calls]).to eq(7)
    end

    it 'replaces the entire sticky_state slot (not a merge)' do
      described_class.append('conv-sticky-4', role: :user, content: 'hi')
      described_class.write_sticky_state('conv-sticky-4', { a: 1, b: 2 })
      described_class.write_sticky_state('conv-sticky-4', { c: 3 })
      result = described_class.read_sticky_state('conv-sticky-4')
      expect(result).to eq({ c: 3 })
      expect(result[:a]).to be_nil
    end

    it 'updates the LRU tick via touch' do
      described_class.append('conv-sticky-5', role: :user, content: 'hi')
      tick_before = described_class.send(:conversations)['conv-sticky-5'][:lru_tick]
      described_class.write_sticky_state('conv-sticky-5', { x: 1 })
      tick_after = described_class.send(:conversations)['conv-sticky-5'][:lru_tick]
      expect(tick_after).to be > tick_before
    end
  end

  describe 'LRU eviction' do
    it 'evicts oldest conversation when capacity exceeded' do
      stub_const('Legion::LLM::Inference::Conversation::MAX_CONVERSATIONS', 2)
      described_class.append('conv_a', role: :user, content: 'a')
      described_class.append('conv_b', role: :user, content: 'b')
      described_class.append('conv_c', role: :user, content: 'c')
      # conv_a should be evicted from memory
      expect(described_class.in_memory?('conv_a')).to be false
      expect(described_class.in_memory?('conv_c')).to be true
    end

    it 'promotes accessed conversation to most-recent' do
      stub_const('Legion::LLM::Inference::Conversation::MAX_CONVERSATIONS', 2)
      described_class.append('conv_a', role: :user, content: 'a')
      described_class.append('conv_b', role: :user, content: 'b')
      described_class.messages('conv_a') # access promotes conv_a
      described_class.append('conv_c', role: :user, content: 'c')
      # conv_b should be evicted (least recently used), not conv_a
      expect(described_class.in_memory?('conv_a')).to be true
      expect(described_class.in_memory?('conv_b')).to be false
    end
  end
end
