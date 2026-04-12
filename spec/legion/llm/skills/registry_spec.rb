# frozen_string_literal: true

require 'spec_helper'
require 'legion/llm/skills/step_result'
require 'legion/llm/skills/skill_run_result'
require 'legion/llm/skills/errors'
require 'legion/llm/skills/base'
require 'legion/llm/skills/registry'

def make_skill(name:, namespace:, trigger: :on_demand, words: [], follows: nil, file_triggers: [])
  klass = Class.new(Legion::LLM::Skills::Base)
  klass.skill_name(name)
  klass.namespace(namespace)
  klass.trigger(trigger)
  klass.trigger_words(*words) if words.any?
  klass.follows(follows) if follows
  klass.file_change_triggers(*file_triggers) if file_triggers.any?
  klass.define_method(:s) { |**| Legion::LLM::Skills::StepResult.build(inject: 's') }
  klass.steps(:s)
  klass
end

RSpec.describe Legion::LLM::Skills::Registry do
  before { described_class.reset! }

  describe '.register / .find' do
    it 'registers and retrieves by namespace:name key' do
      sk = make_skill(name: 'skill-a', namespace: 'test')
      described_class.register(sk)
      expect(described_class.find('test:skill-a')).to eq(sk)
    end

    it 'returns nil for unknown key' do
      expect(described_class.find('nope:nope')).to be_nil
    end
  end

  describe '.all' do
    it 'returns skills in insertion order' do
      a = make_skill(name: 'a', namespace: 'test')
      b = make_skill(name: 'b', namespace: 'test')
      described_class.register(a)
      described_class.register(b)
      expect(described_class.all).to eq([a, b])
    end
  end

  describe '.by_trigger' do
    it 'filters by trigger type' do
      on_demand = make_skill(name: 'od', namespace: 'test', trigger: :on_demand)
      auto      = make_skill(name: 'au', namespace: 'test', trigger: :auto)
      described_class.register(on_demand)
      described_class.register(auto)
      expect(described_class.by_trigger(:auto)).to eq([auto])
      expect(described_class.by_trigger(:on_demand)).to eq([on_demand])
    end
  end

  describe '.chain_for' do
    it 'returns the follower key' do
      a = make_skill(name: 'a', namespace: 'test')
      b = make_skill(name: 'b', namespace: 'test', follows: 'test:a')
      described_class.register(a)
      described_class.register(b)
      expect(described_class.chain_for('test:a')).to eq('test:b')
    end

    it 'returns nil when no follower registered' do
      described_class.register(make_skill(name: 'a', namespace: 'test'))
      expect(described_class.chain_for('test:a')).to be_nil
    end
  end

  describe 'duplicate registration' do
    it 'replaces previous and logs warning (last wins)' do
      v1 = make_skill(name: 'sk', namespace: 'test')
      v2 = make_skill(name: 'sk', namespace: 'test')
      described_class.register(v1)
      expect { described_class.register(v2) }.not_to raise_error
      expect(described_class.find('test:sk')).to eq(v2)
      expect(described_class.all.size).to eq(1)
    end
  end

  describe 'cycle detection' do
    it 'raises InvalidSkill when chain loops back' do
      ca = make_skill(name: 'ca', namespace: 'test', follows: 'test:cb')
      cb = make_skill(name: 'cb', namespace: 'test', follows: 'test:ca')
      described_class.register(ca)
      expect { described_class.register(cb) }
        .to raise_error(Legion::LLM::Skills::InvalidSkill, /Cycle detected/)
    end
  end

  describe 'trigger word index' do
    it 'builds reverse index' do
      sk = make_skill(name: 'sk', namespace: 'test', words: %w[foo bar])
      described_class.register(sk)
      idx = described_class.trigger_word_index
      expect(idx['foo']).to include('test:sk')
      expect(idx['bar']).to include('test:sk')
    end
  end

  describe 'file trigger index' do
    it 'tracks skills with file_change_triggers' do
      sk = make_skill(name: 'sk', namespace: 'test', file_triggers: ['*.rb'])
      described_class.register(sk)
      expect(described_class.file_trigger_skills).to include(sk)
    end
  end
end
