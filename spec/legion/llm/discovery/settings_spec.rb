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

RSpec.describe 'Embedding settings defaults' do
  describe 'embedding settings' do
    it 'includes embedding defaults' do
      expect(Legion::Settings[:llm][:embedding]).to be_a(Hash)
      expect(Legion::Settings[:llm][:embedding][:dimension]).to eq(1024)
    end

    # M4: the selection-domain keys (provider/instance/default_model/model/
    # provider_fallback/provider_models/ollama_preferred) are gone — SSOT
    # :embed routing is the sole embedding selection authority, and no
    # operator pin lives in the settings tree.
    it 'carries no second-selection-domain keys' do
      keys = Legion::Settings[:llm][:embedding].keys
      %i[provider instance default_model model provider_fallback provider_models ollama_preferred].each do |k|
        expect(keys).not_to include(k), "expected embedding[:#{k}] to be removed (M4)"
      end
    end
  end
end
