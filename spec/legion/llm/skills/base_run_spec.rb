# frozen_string_literal: true

require 'spec_helper'
require 'legion/llm/skills/step_result'
require 'legion/llm/skills/skill_run_result'
require 'legion/llm/skills/errors'
require 'legion/llm/skills/base'

RSpec.describe Legion::LLM::Skills::Base, '#run' do
  before do
    stub_const('Legion::Events', Module.new { def self.emit(*); end })
    stub_const('Legion::LLM::Metering', Module.new { def self.emit(**); end })
    stub_const('Legion::LLM::Audit',
               Module.new { def self.emit_skill(**); end })
    allow(Legion::Events).to receive(:emit)
    allow(Legion::LLM::Metering).to receive(:emit)
    allow(Legion::LLM::Audit).to receive(:emit_skill)
    allow(Legion::LLM::ConversationStore).to receive(:skill_cancelled?).and_return(false)
    allow(Legion::LLM::ConversationStore).to receive(:clear_skill_state)
    allow(Legion::LLM::ConversationStore).to receive(:set_skill_state)
    allow(Legion::LLM::ConversationStore).to receive(:clear_cancel_flag)
    stub_const('Legion::LLM::Skills::Registry',
               Module.new do
                 def self.chain_for(_)
                   nil
                 end

                 def self.find(_)
                   nil
                 end
               end)
  end

  let(:skill_class) do
    Class.new(described_class) do
      skill_name 'run-test'
      namespace 'test'
      trigger :on_demand

      def step_a(**) = Legion::LLM::Skills::StepResult.build(inject: 'output_a')
      def step_b(**) = Legion::LLM::Skills::StepResult.build(inject: 'output_b')

      steps :step_a, :step_b
    end
  end

  let(:context) { { conversation_id: 'conv-123', classification: { level: 'internal' } } }

  it 'runs all steps and returns complete result' do
    result = skill_class.new.run(from_step: 0, context: context)
    expect(result.complete).to be true
    expect(result.gated).to be false
    expect(result.inject).to include('output_a')
    expect(result.inject).to include('output_b')
  end

  it 'resumes from from_step' do
    result = skill_class.new.run(from_step: 1, context: context)
    expect(result.inject).not_to include('output_a')
    expect(result.inject).to include('output_b')
  end

  it 'stops at a gate and writes ConversationStore state' do
    allow_any_instance_of(skill_class).to receive(:step_a) do
      Legion::LLM::Skills::StepResult.build(inject: 'gated', gate: :await_user_input)
    end

    result = skill_class.new.run(from_step: 0, context: context)
    expect(result.gated).to be true
    expect(result.gate).to eq(:await_user_input)
    expect(result.resume_at).to eq(1)
    expect(Legion::LLM::ConversationStore).to have_received(:set_skill_state)
      .with('conv-123', skill_key: 'test:run-test', resume_at: 1)
  end

  it 'returns cancelled result when cancel flag set before a step' do
    allow(Legion::LLM::ConversationStore).to receive(:skill_cancelled?).and_return(true)
    result = skill_class.new.run(from_step: 0, context: context)
    expect(result.complete).to be false
    expect(result.gated).to be false
    expect(Legion::LLM::ConversationStore).to have_received(:clear_cancel_flag)
  end

  it 'clears skill state and raises StepError on step exception' do
    allow_any_instance_of(skill_class).to receive(:step_a).and_raise(RuntimeError, 'boom')
    expect { skill_class.new.run(from_step: 0, context: context) }
      .to raise_error(Legion::LLM::Skills::StepError, /run-test#step_a failed: boom/)
    expect(Legion::LLM::ConversationStore).to have_received(:clear_skill_state).with('conv-123')
  end

  it 'emits metering start + end per step (twice per step always)' do
    skill_class.new.run(from_step: 0, context: context)
    expect(Legion::LLM::Metering).to have_received(:emit)
      .with(hash_including(request_type: 'skill.step.start')).exactly(2).times
    expect(Legion::LLM::Metering).to have_received(:emit)
      .with(hash_including(request_type: 'skill.step')).exactly(2).times
  end

  it 'emits metering end on failure path (twice per step always)' do
    allow_any_instance_of(skill_class).to receive(:step_a).and_raise(RuntimeError, 'boom')
    expect { skill_class.new.run(from_step: 0, context: context) }.to raise_error(Legion::LLM::Skills::StepError)
    expect(Legion::LLM::Metering).to have_received(:emit)
      .with(hash_including(request_type: 'skill.step')).once
  end

  context 'with a chain follower' do
    let(:follower_class) do
      Class.new(described_class) do
        skill_name 'follower'
        namespace 'test'
        trigger :on_demand

        def follow_step(**) = Legion::LLM::Skills::StepResult.build(inject: 'chained')

        steps :follow_step
      end
    end

    before do
      allow(Legion::LLM::Skills::Registry).to receive(:chain_for)
        .with('test:run-test').and_return('test:follower')
      allow(Legion::LLM::Skills::Registry).to receive(:chain_for)
        .with('test:follower').and_return(nil)
      allow(Legion::LLM::Skills::Registry).to receive(:find)
        .with('test:follower').and_return(follower_class)
    end

    it 'runs the chained skill inline and merges inject content' do
      result = skill_class.new.run(from_step: 0, context: context)
      expect(result.inject).to include('output_a')
      expect(result.inject).to include('chained')
    end

    it 'does not emit skill.completed with chained_to when class not found' do
      allow(Legion::LLM::Skills::Registry).to receive(:find).with('test:follower').and_return(nil)
      events_emitted = []
      allow(Legion::Events).to receive(:emit) { |name, payload| events_emitted << [name, payload] }
      skill_class.new.run(from_step: 0, context: context)
      completed = events_emitted.find { |n, _| n == 'skill.completed' }
      expect(completed[1][:chained_to]).to be_nil
    end
  end
end
