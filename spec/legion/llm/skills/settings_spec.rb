# frozen_string_literal: true

require 'spec_helper'

RSpec.describe Legion::LLM::Settings do
  describe '.skills_defaults' do
    subject(:defaults) { described_class.skills_defaults }

    it 'sets enabled: true' do
      expect(defaults[:enabled]).to be true
    end

    it 'sets max_active_skills: 1' do
      expect(defaults[:max_active_skills]).to eq(1)
    end

    it 'includes default directories' do
      expect(defaults[:directories]).to include('.legion/skills')
    end

    it 'disables auto_discover for claude and codex by default' do
      expect(defaults[:auto_discover]).to eq(claude: false, codex: false)
    end
  end

  describe 'skills defaults merged into Legion::Settings' do
    it 'populates Legion::Settings[:llm][:skills] via merge_settings' do
      expect(Legion::Settings[:llm][:skills][:enabled]).to be true
      expect(Legion::Settings[:llm][:skills][:max_active_skills]).to eq(1)
    end

    it 'allows caller overrides to win' do
      Legion::Settings[:llm][:skills] = Legion::Settings[:llm][:skills].merge(enabled: false, max_active_skills: 5)
      expect(Legion::Settings[:llm][:skills][:enabled]).to be false
      expect(Legion::Settings[:llm][:skills][:max_active_skills]).to eq(5)
    end
  end
end
