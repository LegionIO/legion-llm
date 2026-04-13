# frozen_string_literal: true

require 'spec_helper'
require 'legion/llm/skills/step_result'

RSpec.describe Legion::LLM::Skills::StepResult do
  describe '.build' do
    it 'builds with required inject, defaulting gate and metadata' do
      result = described_class.build(inject: 'context text')
      expect(result.inject).to eq('context text')
      expect(result.gate).to be_nil
      expect(result.metadata).to eq({})
    end

    it 'accepts gate: :await_user_input' do
      result = described_class.build(inject: 'text', gate: :await_user_input)
      expect(result.gate).to eq(:await_user_input)
    end

    it 'accepts a metadata hash' do
      result = described_class.build(inject: 'text', metadata: { files_read: 3 })
      expect(result.metadata).to eq({ files_read: 3 })
    end
  end
end
