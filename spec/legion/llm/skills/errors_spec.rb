# frozen_string_literal: true

require 'spec_helper'
require 'legion/llm/errors'
require 'legion/llm/skills/errors'

RSpec.describe 'Legion::LLM::Skills errors' do
  describe Legion::LLM::Skills::InvalidSkill do
    it 'inherits from Legion::LLM::LLMError' do
      expect(described_class.ancestors).to include(Legion::LLM::LLMError)
    end

    it 'has a default message' do
      expect(described_class.new.message).to eq('Invalid skill definition')
    end
  end

  describe Legion::LLM::Skills::StepError do
    it 'inherits from Legion::LLM::LLMError' do
      expect(described_class.ancestors).to include(Legion::LLM::LLMError)
    end

    it 'stores the original cause' do
      original = RuntimeError.new('root cause')
      err = described_class.new('step failed', cause: original)
      expect(err.cause).to eq(original)
      expect(err.message).to eq('step failed')
    end
  end
end
