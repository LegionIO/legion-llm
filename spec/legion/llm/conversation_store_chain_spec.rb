# frozen_string_literal: true

require 'spec_helper'

RSpec.describe Legion::LLM::ConversationStore do
  before { described_class.reset! }

  # ──────────────────────────────────────────────────────────────────────
  # append with new fields
  # ──────────────────────────────────────────────────────────────────────
  describe '.append with chain fields' do
    it 'assigns a UUID id to each message' do
      msg = described_class.append('conv_1', role: :user, content: 'hello')
      expect(msg[:id]).to match(/\A[0-9a-f-]{36}\z/)
    end

    it 'stores parent_id when supplied' do
      first  = described_class.append('conv_1', role: :user, content: 'first')
      second = described_class.append('conv_1', role: :assistant, content: 'second',
                                               parent_id: first[:id])
      expect(second[:parent_id]).to eq(first[:id])
    end

    it 'defaults sidechain to false' do
      msg = described_class.append('conv_1', role: :user, content: 'hello')
      expect(msg[:sidechain]).to be false
    end

    it 'stores sidechain: true' do
      msg = described_class.append('conv_1', role: :assistant, content: 'bg',
                                            sidechain: true, agent_id: 'curator')
      expect(msg[:sidechain]).to be true
      expect(msg[:agent_id]).to eq('curator')
    end

    it 'stores message_group_id' do
      group = SecureRandom.uuid
      msg   = described_class.append('conv_1', role: :assistant, content: 'a',
                                              message_group_id: group)
      expect(msg[:message_group_id]).to eq(group)
    end

    it 'defaults parent_id, sidechain, message_group_id, agent_id to nil/false when omitted' do
      msg = described_class.append('conv_1', role: :user, content: 'hi')
      expect(msg[:parent_id]).to be_nil
      expect(msg[:sidechain]).to be false
      expect(msg[:message_group_id]).to be_nil
      expect(msg[:agent_id]).to be_nil
    end
  end

  # ──────────────────────────────────────────────────────────────────────
  # build_chain — ordered chain from parent links
  # ──────────────────────────────────────────────────────────────────────
  describe '.build_chain' do
    it 'returns empty array for unknown conversation' do
      expect(described_class.build_chain('no_such_conv')).to eq([])
    end

    it 'returns messages in parent-link order' do
      a = described_class.append('c', role: :user, content: 'a')
      b = described_class.append('c', role: :assistant, content: 'b', parent_id: a[:id])
      described_class.append('c', role: :user, content: 'c', parent_id: b[:id])

      chain = described_class.build_chain('c')
      expect(chain.map { |m| m[:content] }).to eq(%w[a b c])
    end

    it 'excludes sidechain messages by default' do
      a = described_class.append('c', role: :user, content: 'main')
      described_class.append('c', role: :assistant, content: 'side',
                                   sidechain: true, agent_id: 'bot', parent_id: a[:id])
      described_class.append('c', role: :assistant, content: 'reply', parent_id: a[:id])

      chain = described_class.build_chain('c')
      expect(chain.map { |m| m[:content] }).not_to include('side')
      expect(chain.map { |m| m[:content] }).to include('main')
    end

    it 'includes sidechain messages when include_sidechains: true' do
      a = described_class.append('c', role: :user, content: 'main')
      described_class.append('c', role: :assistant, content: 'side',
                                   sidechain: true, agent_id: 'bot', parent_id: a[:id])

      chain = described_class.build_chain('c', include_sidechains: true)
      expect(chain.map { |m| m[:content] }).to include('side')
    end

    it 'falls back to seq ordering for messages without parent links' do
      described_class.append('c', role: :user, content: 'first')
      described_class.append('c', role: :assistant, content: 'second')
      chain = described_class.build_chain('c')
      expect(chain.map { |m| m[:content] }).to eq(%w[first second])
    end

    it 'handles a single message' do
      described_class.append('c', role: :user, content: 'only')
      chain = described_class.build_chain('c')
      expect(chain.size).to eq(1)
      expect(chain.first[:content]).to eq('only')
    end

    it 'excludes metadata entries' do
      described_class.append('c', role: :user, content: 'hello')
      described_class.store_metadata('c', title: 'My Session')
      chain = described_class.build_chain('c')
      expect(chain.map { |m| m[:role] }).not_to include(Legion::LLM::ConversationStore::METADATA_ROLE)
    end
  end

  # ──────────────────────────────────────────────────────────────────────
  # API round grouping — recover parallel siblings
  # ──────────────────────────────────────────────────────────────────────
  describe 'API round grouping' do
    it 'recovers parallel sibling messages in same message_group_id' do
      group = SecureRandom.uuid
      # Simulate two parallel tool result messages from the same API round
      a  = described_class.append('c', role: :user, content: 'query')
      t1 = described_class.append('c', role: :tool, content: 'result_1',
                                        parent_id: a[:id], message_group_id: group)
      described_class.append('c', role: :tool, content: 'result_2',
                                        parent_id: a[:id], message_group_id: group)
      # Main chain continues from t1 only
      described_class.append('c', role: :assistant, content: 'answer', parent_id: t1[:id])

      chain = described_class.build_chain('c')
      contents = chain.map { |m| m[:content] }
      expect(contents).to include('result_1')
      expect(contents).to include('result_2')
    end
  end

  # ──────────────────────────────────────────────────────────────────────
  # sidechain_messages
  # ──────────────────────────────────────────────────────────────────────
  describe '.sidechain_messages' do
    before do
      described_class.append('c', role: :user, content: 'main message')
      described_class.append('c', role: :assistant, content: 'curator thought',
                                   sidechain: true, agent_id: 'curator')
      described_class.append('c', role: :assistant, content: 'planner thought',
                                   sidechain: true, agent_id: 'planner')
    end

    it 'returns all sidechain messages when no agent_id filter' do
      result = described_class.sidechain_messages('c')
      expect(result.map { |m| m[:content] }).to match_array(['curator thought', 'planner thought'])
    end

    it 'filters by agent_id when provided' do
      result = described_class.sidechain_messages('c', agent_id: 'curator')
      expect(result.size).to eq(1)
      expect(result.first[:content]).to eq('curator thought')
    end

    it 'excludes main-chain messages' do
      result = described_class.sidechain_messages('c')
      expect(result.map { |m| m[:content] }).not_to include('main message')
    end

    it 'returns empty array when no sidechain messages exist' do
      described_class.create_conversation('empty_conv')
      expect(described_class.sidechain_messages('empty_conv')).to eq([])
    end
  end

  # ──────────────────────────────────────────────────────────────────────
  # branch
  # ──────────────────────────────────────────────────────────────────────
  describe '.branch' do
    it 'creates a new conversation with copied history up to from_message_id' do
      a = described_class.append('orig', role: :user, content: 'msg_a')
      b = described_class.append('orig', role: :assistant, content: 'msg_b', parent_id: a[:id])
      described_class.append('orig', role: :user, content: 'msg_c', parent_id: b[:id])

      new_conv_id = described_class.branch('orig', from_message_id: b[:id])
      expect(new_conv_id).not_to eq('orig')
      expect(described_class.conversation_exists?(new_conv_id)).to be true

      branched = described_class.messages(new_conv_id)
      expect(branched.map { |m| m[:content] }).to eq(%w[msg_a msg_b])
    end

    it 'raises ArgumentError when from_message_id is not found' do
      described_class.append('orig', role: :user, content: 'only')
      expect do
        described_class.branch('orig', from_message_id: SecureRandom.uuid)
      end.to raise_error(ArgumentError, /not found/)
    end

    it 'assigns new UUIDs to copied messages' do
      a = described_class.append('orig', role: :user, content: 'hello')
      new_conv_id = described_class.branch('orig', from_message_id: a[:id])
      branched = described_class.messages(new_conv_id)
      expect(branched.first[:id]).not_to eq(a[:id])
    end

    it 'returns a valid UUID for the new conversation id' do
      a = described_class.append('orig', role: :user, content: 'hello')
      new_conv_id = described_class.branch('orig', from_message_id: a[:id])
      expect(new_conv_id).to match(/\A[0-9a-f-]{36}\z/)
    end
  end

  # ──────────────────────────────────────────────────────────────────────
  # tail-window metadata
  # ──────────────────────────────────────────────────────────────────────
  describe 'tail-window metadata' do
    it 'stores and reads metadata' do
      described_class.store_metadata('c', title: 'My Chat', tags: %w[ai llm], model: 'claude-3')
      meta = described_class.read_metadata('c')
      expect(meta[:title]).to eq('My Chat')
      expect(meta[:tags]).to eq(%w[ai llm])
      expect(meta[:model]).to eq('claude-3')
    end

    it 'returns nil when no metadata stored' do
      described_class.create_conversation('empty')
      expect(described_class.read_metadata('empty')).to be_nil
    end

    it 'metadata does not appear in messages()' do
      described_class.append('c', role: :user, content: 'hello')
      described_class.store_metadata('c', title: 'Session 1')
      msgs = described_class.messages('c')
      expect(msgs.map { |m| m[:role] }).not_to include(Legion::LLM::ConversationStore::METADATA_ROLE)
    end

    it 'returns most recent metadata when multiple entries exist' do
      described_class.store_metadata('c', title: 'First')
      described_class.store_metadata('c', title: 'Second')
      meta = described_class.read_metadata('c')
      expect(meta[:title]).to eq('Second')
    end

    it 'partial metadata fields are stored without nil keys' do
      described_class.store_metadata('c', title: 'Partial')
      meta = described_class.read_metadata('c')
      expect(meta[:title]).to eq('Partial')
      expect(meta.key?(:tags)).to be false
    end
  end

  # ──────────────────────────────────────────────────────────────────────
  # backward compatibility
  # ──────────────────────────────────────────────────────────────────────
  describe 'backward compatibility' do
    it 'messages() returns flat ordered array for conversations without parent links' do
      described_class.append('c', role: :user, content: 'first')
      described_class.append('c', role: :assistant, content: 'second')
      described_class.append('c', role: :user, content: 'third')
      contents = described_class.messages('c').map { |m| m[:content] }
      expect(contents).to eq(%w[first second third])
    end

    it 'appending without new fields still works' do
      msg = described_class.append('c', role: :user, content: 'legacy')
      expect(msg[:seq]).to eq(1)
      expect(msg[:role]).to eq(:user)
    end

    it 'seq numbers remain sequential' do
      described_class.append('c', role: :user, content: 'a')
      described_class.append('c', role: :assistant, content: 'b')
      msgs = described_class.messages('c')
      expect(msgs.map { |m| m[:seq] }).to eq([1, 2])
    end

    it 'provider and token metadata still stored' do
      described_class.append('c', role: :assistant, content: 'hi',
                                   provider: :anthropic, model: 'claude-opus-4-6',
                                   input_tokens: 10, output_tokens: 5)
      msg = described_class.messages('c').first
      expect(msg[:provider]).to eq(:anthropic)
      expect(msg[:input_tokens]).to eq(10)
    end
  end

  # ──────────────────────────────────────────────────────────────────────
  # migrate_parent_links!
  # ──────────────────────────────────────────────────────────────────────
  describe '.migrate_parent_links!' do
    it 'links existing sequential messages by parent_id' do
      described_class.append('c', role: :user, content: 'msg1')
      described_class.append('c', role: :assistant, content: 'msg2')
      described_class.append('c', role: :user, content: 'msg3')

      described_class.migrate_parent_links!('c')

      msgs = described_class.messages('c')
      expect(msgs[0][:parent_id]).to be_nil
      expect(msgs[1][:parent_id]).to eq(msgs[0][:id])
      expect(msgs[2][:parent_id]).to eq(msgs[1][:id])
    end

    it 'is a no-op when messages already have parent links' do
      a = described_class.append('c', role: :user, content: 'a')
      described_class.append('c', role: :assistant, content: 'b', parent_id: a[:id])

      described_class.migrate_parent_links!('c')

      msgs = described_class.messages('c')
      # Second message parent_id remains unchanged (already set)
      expect(msgs[1][:parent_id]).to eq(a[:id])
    end

    it 'is a no-op for empty conversation' do
      described_class.create_conversation('empty')
      expect { described_class.migrate_parent_links!('empty') }.not_to raise_error
    end
  end

  # ──────────────────────────────────────────────────────────────────────
  # edge cases
  # ──────────────────────────────────────────────────────────────────────
  describe 'edge cases' do
    it 'build_chain on empty conversation returns empty array' do
      described_class.create_conversation('empty')
      expect(described_class.build_chain('empty')).to eq([])
    end

    it 'orphaned messages (no parent chain match) appear at end' do
      a = described_class.append('c', role: :user, content: 'root')
      described_class.append('c', role: :assistant, content: 'child', parent_id: a[:id])
      # Manually inject an orphan (parent_id points to non-existent message)
      described_class.append('c', role: :user, content: 'orphan', parent_id: 'non-existent-uuid')

      chain = described_class.build_chain('c')
      expect(chain.last[:content]).to eq('orphan')
      expect(chain.first[:content]).to eq('root')
    end

    it 'branch with only one message creates single-message branch' do
      a = described_class.append('orig', role: :user, content: 'only')
      new_id = described_class.branch('orig', from_message_id: a[:id])
      expect(described_class.messages(new_id).size).to eq(1)
    end

    it 'sidechain_messages returns empty for unknown conversation' do
      expect(described_class.sidechain_messages('ghost')).to eq([])
    end
  end
end
