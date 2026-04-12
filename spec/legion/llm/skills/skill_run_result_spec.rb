# frozen_string_literal: true

require 'spec_helper'
require 'legion/llm/skills/skill_run_result'

RSpec.describe Legion::LLM::Skills::SkillRunResult do
  describe '.build' do
    it 'builds a complete result' do
      result = described_class.build(inject: 'all done', gated: false,
                                     gate: nil, resume_at: nil, complete: true)
      expect(result.complete).to be true
      expect(result.gated).to be false
      expect(result.inject).to eq('all done')
    end

    it 'builds a gated result' do
      result = described_class.build(inject: 'partial', gated: true,
                                     gate: :await_user_input, resume_at: 2, complete: false)
      expect(result.gated).to be true
      expect(result.gate).to eq(:await_user_input)
      expect(result.resume_at).to eq(2)
      expect(result.complete).to be false
    end
  end
end
