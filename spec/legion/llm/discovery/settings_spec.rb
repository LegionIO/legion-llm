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
      expect(Legion::Settings[:llm][:embedding][:provider_fallback]).to eq(%w[azure ollama bedrock openai])
    end

    it 'includes ollama preferred models' do
      preferred = Legion::Settings[:llm][:embedding][:ollama_preferred]
      expect(preferred).to include('nomic-embed-text', 'mxbai-embed-large')
      expect(preferred.size).to eq(4)
    end
  end
end
