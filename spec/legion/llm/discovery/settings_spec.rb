# frozen_string_literal: true

require 'spec_helper'

RSpec.describe 'Discovery settings defaults' do
  it 'includes discovery key in LLM settings' do
    expect(Legion::Settings[:llm][:discovery]).to be_a(Hash)
  end

  it 'defaults enabled to true' do
    expect(Legion::Settings[:llm][:discovery][:enabled]).to be true
  end

  it 'defaults refresh_seconds to 60' do
    expect(Legion::Settings[:llm][:discovery][:refresh_seconds]).to eq(60)
  end

  it 'defaults memory_floor_mb to 2048' do
    expect(Legion::Settings[:llm][:discovery][:memory_floor_mb]).to eq(2048)
  end
end
