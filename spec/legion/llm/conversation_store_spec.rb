# frozen_string_literal: true

require 'spec_helper'

RSpec.describe Legion::LLM::ConversationStore do
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

  describe 'LRU eviction' do
    it 'evicts oldest conversation when capacity exceeded' do
      stub_const('Legion::LLM::ConversationStore::MAX_CONVERSATIONS', 2)
      described_class.append('conv_a', role: :user, content: 'a')
      described_class.append('conv_b', role: :user, content: 'b')
      described_class.append('conv_c', role: :user, content: 'c')
      # conv_a should be evicted from memory
      expect(described_class.in_memory?('conv_a')).to be false
      expect(described_class.in_memory?('conv_c')).to be true
    end

    it 'promotes accessed conversation to most-recent' do
      stub_const('Legion::LLM::ConversationStore::MAX_CONVERSATIONS', 2)
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
