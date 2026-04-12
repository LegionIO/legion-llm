# frozen_string_literal: true

require 'spec_helper'
require 'legion/llm/skills/step_result'
require 'legion/llm/skills/skill_run_result'
require 'legion/llm/skills/errors'
require 'legion/llm/skills/base'
require 'legion/llm/skills/registry'
require 'legion/llm/pipeline/steps/skill_injector'

RSpec.describe Legion::LLM::Pipeline::Steps::SkillInjector do
  let(:executor_class) do
    Class.new do
      include Legion::LLM::Pipeline::Steps::SkillInjector

      attr_accessor :request, :enrichments, :warnings

      def initialize(request)
        @request = request
        @enrichments = {}
        @warnings    = []
      end

      def log
        @log ||= Logger.new(nil)
      end

      def handle_exception(err, **); end
    end
  end

  let(:request) do
    double(:request,
           conversation_id: 'conv-1',
           messages:        [{ role: :user, content: 'let me brainstorm this' }],
           metadata:        {},
           classification:  nil,
           extra:           nil)
  end

  let(:executor) { executor_class.new(request) }

  before do
    Legion::LLM::Skills::Registry.reset!
    allow(Legion::LLM::ConversationStore).to receive(:skill_state).and_return(nil)
    allow(Legion::LLM::ConversationStore).to receive(:skill_cancelled?).and_return(false)
    allow(Legion::LLM::ConversationStore).to receive(:clear_skill_state)
    allow(Legion::LLM::ConversationStore).to receive(:set_skill_state)
    allow(Legion::LLM::ConversationStore).to receive(:clear_cancel_flag)
    allow(Legion::Events).to receive(:emit) if defined?(Legion::Events)
    allow(Legion::LLM::Metering).to receive(:emit) if defined?(Legion::LLM::Metering)
    allow(Legion::LLM::Audit).to receive(:emit_skill) if defined?(Legion::LLM::Audit)
    allow(Legion::LLM).to receive(:settings).and_return(
      skills: { enabled: true, auto_inject: true, max_active_skills: 1,
                disabled_skills: [], enabled_skills: [] }
    )
    stub_const('Legion::Events', Module.new { def self.emit(*); end }) unless defined?(Legion::Events)
    stub_const('Legion::LLM::Metering', Module.new { def self.emit(**); end }) unless Legion::LLM.const_defined?(:Metering)
    allow(Legion::Events).to receive(:emit)
    allow(Legion::LLM::Metering).to receive(:emit)
    allow(Legion::LLM::Audit).to receive(:emit_skill)
  end

  after { Legion::LLM::Skills::Registry.reset! }

  describe 'trigger word matching' do
    let(:skill_class) do
      klass = Class.new(Legion::LLM::Skills::Base)
      klass.skill_name('brainstorming')
      klass.namespace('superpowers')
      klass.trigger(:on_demand)
      klass.trigger_words('brainstorm')
      klass.define_method(:s) { |**| Legion::LLM::Skills::StepResult.build(inject: 'injected content') }
      klass.steps(:s)
      klass
    end

    it 'activates a matching skill and sets skill:active enrichment' do
      Legion::LLM::Skills::Registry.register(skill_class)
      executor.step_skill_injector
      expect(executor.enrichments['skill:active']).to eq('injected content')
    end
  end

  describe 'no-op when skills disabled' do
    it 'does nothing when skills.enabled is false' do
      allow(Legion::LLM).to receive(:settings).and_return({ skills: { enabled: false } })
      executor.step_skill_injector
      expect(executor.enrichments).to be_empty
    end
  end

  describe 'resume active skill from ConversationStore' do
    let(:skill_class) do
      klass = Class.new(Legion::LLM::Skills::Base)
      klass.skill_name('sk')
      klass.namespace('test')
      klass.trigger(:on_demand)
      klass.define_method(:step2) { |**| Legion::LLM::Skills::StepResult.build(inject: 'resumed') }
      klass.steps(:step2)
      klass
    end

    it 'resumes an active skill from the stored resume_at index' do
      Legion::LLM::Skills::Registry.register(skill_class)
      allow(Legion::LLM::ConversationStore).to receive(:skill_state).and_return(
        { skill_key: 'test:sk', resume_at: 0 }
      )
      executor.step_skill_injector
      expect(executor.enrichments['skill:active']).to eq('resumed')
    end
  end

  describe 'file change triggers' do
    let(:skill_class) do
      klass = Class.new(Legion::LLM::Skills::Base)
      klass.skill_name('rubocop')
      klass.namespace('ruby')
      klass.trigger(:on_demand)
      klass.file_change_triggers('*.rb')
      klass.define_method(:lint) { |**| Legion::LLM::Skills::StepResult.build(inject: 'linting') }
      klass.steps(:lint)
      klass
    end

    it 'activates when a changed file matches a pattern' do
      Legion::LLM::Skills::Registry.register(skill_class)
      allow(request).to receive(:metadata).and_return({ changed_files: ['lib/foo.rb'] })
      executor.step_skill_injector
      expect(executor.enrichments['skill:active']).to eq('linting')
    end

    it 'does not activate for non-matching file extensions' do
      Legion::LLM::Skills::Registry.register(skill_class)
      allow(request).to receive(:metadata).and_return({ changed_files: ['README.md'] })
      executor.step_skill_injector
      expect(executor.enrichments['skill:active']).to be_nil
    end
  end
end
