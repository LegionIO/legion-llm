# frozen_string_literal: true

require 'spec_helper'
require 'legion/llm/skills/step_result'
require 'legion/llm/skills/skill_run_result'
require 'legion/llm/skills/errors'
require 'legion/llm/skills/base'

RSpec.describe Legion::LLM::Skills::Base do
  let(:skill_class) do
    Class.new(described_class) do
      skill_name   'my-skill'
      namespace    'test'
      description  'A test skill'
      trigger      :on_demand
      trigger_words 'foo', 'bar'
      file_change_triggers '*.rb', 'Gemfile'

      # Methods MUST be defined before steps() per plan critical decision #4
      def step_one(context: {}); StepResult.build(inject: 'one'); end
      def step_two(context: {}); StepResult.build(inject: 'two'); end

      steps :step_one, :step_two
    end
  end

  describe 'DSL readers' do
    it 'reads skill_name' do
      expect(skill_class.skill_name).to eq('my-skill')
    end

    it 'reads namespace' do
      expect(skill_class.namespace).to eq('test')
    end

    it 'reads trigger' do
      expect(skill_class.trigger).to eq(:on_demand)
    end

    it 'reads trigger_words' do
      expect(skill_class.trigger_words).to eq(%w[foo bar])
    end

    it 'reads file_change_trigger_patterns' do
      expect(skill_class.file_change_trigger_patterns).to eq(['*.rb', 'Gemfile'])
    end

    it 'reads steps' do
      expect(skill_class.steps).to eq(%i[step_one step_two])
    end

    it 'defaults trigger to :on_demand when not set' do
      klass = Class.new(described_class) do
        skill_name 'x'; namespace 'y'
        def s(context: {}); end
        steps :s
      end
      expect(klass.trigger).to eq(:on_demand)
    end
  end

  describe 'step validation' do
    it 'raises InvalidSkill at class definition time for missing step methods' do
      expect do
        Class.new(described_class) do
          skill_name 'bad'; namespace 'test'
          steps :nonexistent_method
        end
      end.to raise_error(Legion::LLM::Skills::InvalidSkill, /missing step methods/)
    end
  end

  describe '.content' do
    it 'generates content from step names when no SKILL.md exists' do
      content = skill_class.content
      expect(content).to include('my-skill')
      expect(content).to include('Step one')
      expect(content).to include('Step two')
    end
  end

  describe 'condition DSL' do
    it 'stores when_conditions' do
      klass = Class.new(described_class) do
        skill_name 'cond-skill'; namespace 'test'; trigger :auto
        condition classification: { level: 'internal' }
        def s(context: {}); end
        steps :s
      end
      expect(klass.when_conditions).to eq({ classification: { level: 'internal' } })
    end

    it 'defaults when_conditions to empty hash' do
      expect(skill_class.when_conditions).to eq({})
    end
  end
end
