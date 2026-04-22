# frozen_string_literal: true

require 'spec_helper'
require_relative '../../../support/transport_stub'
require 'legion/llm/transport/exchanges/audit'
require 'legion/llm/transport/messages/skill_event'

RSpec.describe Legion::LLM::Transport::Messages::SkillEvent do
  let(:event) do
    described_class.new(
      skill_name: 'brainstorming', namespace: 'superpowers',
      step_name: 'explore_context', gate: :await_user_input,
      status: :completed, duration_ms: 42,
      classification: { level: 'internal', contains_phi: false }
    )
  end

  describe '#routing_key' do
    it 'uses audit.skill.namespace.name format' do
      expect(event.routing_key).to eq('audit.skill.superpowers.brainstorming')
    end
  end

  describe '#encrypt?' do
    it 'is always true' do
      expect(event.encrypt?).to be true
    end
  end

  describe '#headers' do
    subject(:headers) { event.headers }

    it 'includes skill-specific headers' do
      expect(headers['x-legion-skill-name']).to eq('brainstorming')
      expect(headers['x-legion-skill-namespace']).to eq('superpowers')
      expect(headers['x-legion-skill-step']).to eq('explore_context')
      expect(headers['x-legion-skill-gate']).to eq('await_user_input')
      expect(headers['x-legion-skill-status']).to eq('completed')
    end

    it 'includes classification headers' do
      expect(headers['x-legion-classification']).to eq('internal')
      expect(headers['x-legion-contains-phi']).to eq('false')
    end
  end
end
