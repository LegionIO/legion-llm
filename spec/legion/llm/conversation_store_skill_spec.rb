# frozen_string_literal: true

require 'spec_helper'
require 'legion/llm/conversation_store'

RSpec.describe Legion::LLM::ConversationStore, 'skill state' do
  before { described_class.reset! }

  let(:conv_id) { 'conv-skill-test' }

  describe '.set_skill_state / .skill_state' do
    it 'stores and retrieves skill state' do
      described_class.set_skill_state(conv_id,
                                      skill_key: 'superpowers:brainstorming', resume_at: 3)
      state = described_class.skill_state(conv_id)
      expect(state[:skill_key]).to eq('superpowers:brainstorming')
      expect(state[:resume_at]).to eq(3)
    end

    it 'returns nil when no skill state set' do
      described_class.create_conversation(conv_id)
      expect(described_class.skill_state(conv_id)).to be_nil
    end
  end

  describe '.clear_skill_state' do
    it 'removes skill state' do
      described_class.set_skill_state(conv_id, skill_key: 'test', resume_at: 1)
      described_class.clear_skill_state(conv_id)
      expect(described_class.skill_state(conv_id)).to be_nil
    end

    it 'is safe to call when no conversation exists' do
      expect { described_class.clear_skill_state('nonexistent') }.not_to raise_error
    end
  end

  describe '.cancel_skill!' do
    it 'returns state, clears skill_state, sets skill_cancelled' do
      described_class.set_skill_state(conv_id, skill_key: 'test:skill', resume_at: 2)
      state = described_class.cancel_skill!(conv_id)
      expect(state[:skill_key]).to eq('test:skill')
      expect(described_class.skill_state(conv_id)).to be_nil
      expect(described_class.skill_cancelled?(conv_id)).to be true
    end

    it 'returns nil and does NOT set flag when no skill is active' do
      described_class.create_conversation(conv_id)
      state = described_class.cancel_skill!(conv_id)
      expect(state).to be_nil
      expect(described_class.skill_cancelled?(conv_id)).to be false
    end
  end

  describe '.skill_cancelled? / .clear_cancel_flag' do
    it 'is false by default' do
      described_class.create_conversation(conv_id)
      expect(described_class.skill_cancelled?(conv_id)).to be false
    end

    it 'clear_cancel_flag clears only the flag, skill_state remains independent' do
      described_class.set_skill_state(conv_id, skill_key: 'test', resume_at: 1)
      described_class.cancel_skill!(conv_id)
      described_class.clear_cancel_flag(conv_id)
      expect(described_class.skill_cancelled?(conv_id)).to be false
    end

    it 'skill_state nil does NOT imply cancelled (independent flags)' do
      described_class.create_conversation(conv_id)
      # Normal completion: skill_state nil, skill_cancelled false
      expect(described_class.skill_state(conv_id)).to be_nil
      expect(described_class.skill_cancelled?(conv_id)).to be false
    end
  end
end
