# frozen_string_literal: true

require 'spec_helper'
require 'legion/llm/skills/settings'

RSpec.describe Legion::LLM::Skills::Settings do
  before do
    Legion::Settings[:llm].delete(:skills)
    described_class.apply
  end

  it 'sets enabled: true' do
    expect(Legion::Settings[:llm][:skills][:enabled]).to be true
  end

  it 'sets max_active_skills: 1' do
    expect(Legion::Settings[:llm][:skills][:max_active_skills]).to eq(1)
  end

  it 'sets default directories' do
    expect(Legion::Settings[:llm][:skills][:directories]).to include('.legion/skills')
  end

  it 'preserves caller-supplied overrides' do
    Legion::Settings[:llm][:skills] = { enabled: false, max_active_skills: 3 }
    described_class.apply
    expect(Legion::Settings[:llm][:skills][:enabled]).to be false
    expect(Legion::Settings[:llm][:skills][:max_active_skills]).to eq(3)
  end
end
