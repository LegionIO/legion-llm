# frozen_string_literal: true

require 'spec_helper'
require 'legion/llm/discovery/ollama'

RSpec.describe Legion::LLM::Discovery::Ollama do
  before { described_class.reset! }

  let(:tags_response) do
    {
      'models' => [
        { 'name' => 'llama3.1:8b',       'size' => 4_700_000_000, 'digest' => 'sha256:abc' },
        { 'name' => 'qwen2.5:32b',       'size' => 20_000_000_000, 'digest' => 'sha256:def' },
        { 'name' => 'nomic-embed-text', 'size' => 274_000_000, 'digest' => 'sha256:ghi' }
      ]
    }
  end

  before do
    stub_request(:get, 'http://localhost:11434/api/tags')
      .to_return(status: 200, body: tags_response.to_json, headers: { 'Content-Type' => 'application/json' })
  end

  describe '.models' do
    it 'returns array of model hashes from Ollama' do
      expect(described_class.models).to be_an(Array)
      expect(described_class.models.size).to eq(3)
    end

    it 'includes model name and size' do
      model = described_class.models.first
      expect(model['name']).to eq('llama3.1:8b')
      expect(model['size']).to eq(4_700_000_000)
    end
  end

  describe '.model_names' do
    it 'returns array of model name strings' do
      expect(described_class.model_names).to eq(['llama3.1:8b', 'qwen2.5:32b', 'nomic-embed-text'])
    end
  end

  describe '.model_available?' do
    it 'returns true for a pulled model' do
      expect(described_class.model_available?('llama3.1:8b')).to be true
    end

    it 'returns false for a model not pulled' do
      expect(described_class.model_available?('nonexistent:latest')).to be false
    end
  end

  describe '.model_size' do
    it 'returns size in bytes for a known model' do
      expect(described_class.model_size('qwen2.5:32b')).to eq(20_000_000_000)
    end

    it 'returns nil for an unknown model' do
      expect(described_class.model_size('nonexistent:latest')).to be_nil
    end
  end

  describe 'when Ollama is not running' do
    before do
      described_class.reset!
      stub_request(:get, 'http://localhost:11434/api/tags').to_timeout
    end

    it 'returns empty array for models' do
      expect(described_class.models).to eq([])
    end

    it 'returns false for model_available?' do
      expect(described_class.model_available?('llama3.1:8b')).to be false
    end
  end

  describe 'when Ollama returns non-200' do
    before do
      described_class.reset!
      stub_request(:get, 'http://localhost:11434/api/tags').to_return(status: 500, body: 'error')
    end

    it 'returns empty array for models' do
      expect(described_class.models).to eq([])
    end
  end

  describe '.stale?' do
    it 'returns true when never refreshed' do
      expect(described_class.stale?).to be true
    end

    it 'returns false immediately after refresh' do
      described_class.refresh!
      expect(described_class.stale?).to be false
    end
  end

  describe '.reset!' do
    it 'clears cached models' do
      described_class.refresh!
      expect(described_class.models.size).to eq(3)
      described_class.reset!
      stub_request(:get, 'http://localhost:11434/api/tags')
        .to_return(status: 200, body: { 'models' => [] }.to_json)
      expect(described_class.models).to eq([])
    end
  end

  describe 'TTL-based staleness' do
    it 'uses refresh_seconds from settings' do
      Legion::Settings[:llm][:discovery] = { enabled: true, refresh_seconds: 10 }
      described_class.refresh!
      expect(described_class.stale?).to be false

      described_class.instance_variable_set(:@last_refreshed_at, Time.now - 11)
      expect(described_class.stale?).to be true
    end
  end

  describe 'custom base_url' do
    before do
      described_class.reset!
      Legion::Settings[:llm][:providers][:ollama][:base_url] = 'http://gpu-server:11434'
      stub_request(:get, 'http://gpu-server:11434/api/tags')
        .to_return(status: 200, body: tags_response.to_json, headers: { 'Content-Type' => 'application/json' })
    end

    it 'queries the configured base_url' do
      described_class.refresh!
      expect(described_class.model_names).to eq(['llama3.1:8b', 'qwen2.5:32b', 'nomic-embed-text'])
    end
  end
end
