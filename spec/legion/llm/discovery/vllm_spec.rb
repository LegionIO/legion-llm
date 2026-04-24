# frozen_string_literal: true

require 'spec_helper'
require 'legion/llm/discovery/vllm'

RSpec.describe Legion::LLM::Discovery::Vllm do
  before do
    described_class.reset!
    Legion::Settings[:llm][:providers][:vllm] = {
      enabled: true, base_url: 'http://gpu-server:8000/v1'
    }
  end

  let(:models_response) do
    {
      'object' => 'list',
      'data'   => [
        {
          'id'            => 'qwen3.6-27b',
          'object'        => 'model',
          'created'       => 1_777_010_712,
          'owned_by'      => 'vllm',
          'root'          => '/data/models/qwen3.6-27b',
          'max_model_len' => 32_768
        }
      ]
    }
  end

  before do
    stub_request(:get, 'http://gpu-server:8000/v1/models')
      .to_return(status: 200, body: models_response.to_json,
                 headers: { 'Content-Type' => 'application/json' })
  end

  describe '.models' do
    it 'returns array of model hashes from vLLM' do
      expect(described_class.models).to be_an(Array)
      expect(described_class.models.size).to eq(1)
    end

    it 'includes model id and max_model_len' do
      model = described_class.models.first
      expect(model['id']).to eq('qwen3.6-27b')
      expect(model['max_model_len']).to eq(32_768)
    end
  end

  describe '.model_names' do
    it 'returns array of model id strings' do
      expect(described_class.model_names).to eq(['qwen3.6-27b'])
    end
  end

  describe '.model_available?' do
    it 'returns true for a loaded model' do
      expect(described_class.model_available?('qwen3.6-27b')).to be true
    end

    it 'returns false for a model not loaded' do
      expect(described_class.model_available?('nonexistent')).to be false
    end
  end

  describe '.max_context' do
    it 'returns max_model_len for a known model' do
      expect(described_class.max_context('qwen3.6-27b')).to eq(32_768)
    end

    it 'returns nil for an unknown model' do
      expect(described_class.max_context('nonexistent')).to be_nil
    end
  end

  describe '.healthy?' do
    it 'returns true when /health returns 200' do
      stub_request(:get, 'http://gpu-server:8000/health')
        .to_return(status: 200)
      expect(described_class.healthy?).to be true
    end

    it 'returns false when /health returns non-200' do
      stub_request(:get, 'http://gpu-server:8000/health')
        .to_return(status: 503)
      expect(described_class.healthy?).to be false
    end

    it 'returns false when /health times out' do
      stub_request(:get, 'http://gpu-server:8000/health').to_timeout
      expect(described_class.healthy?).to be false
    end
  end

  describe 'when vLLM is not running' do
    before do
      described_class.reset!
      stub_request(:get, 'http://gpu-server:8000/v1/models').to_timeout
    end

    it 'returns empty array for models' do
      expect(described_class.models).to eq([])
    end

    it 'returns false for model_available?' do
      expect(described_class.model_available?('qwen3.6-27b')).to be false
    end

    it 'returns nil for max_context' do
      expect(described_class.max_context('qwen3.6-27b')).to be_nil
    end
  end

  describe 'when vLLM returns non-200' do
    before do
      described_class.reset!
      stub_request(:get, 'http://gpu-server:8000/v1/models')
        .to_return(status: 500, body: 'error')
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
      expect(described_class.models.size).to eq(1)
      described_class.reset!
      stub_request(:get, 'http://gpu-server:8000/v1/models')
        .to_return(status: 200, body: { 'data' => [] }.to_json)
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

  describe 'multiple models' do
    let(:multi_model_response) do
      {
        'data' => [
          { 'id' => 'qwen3.6-27b', 'max_model_len' => 32_768, 'owned_by' => 'vllm' },
          { 'id' => 'llama-70b', 'max_model_len' => 131_072, 'owned_by' => 'vllm' }
        ]
      }
    end

    before do
      described_class.reset!
      stub_request(:get, 'http://gpu-server:8000/v1/models')
        .to_return(status: 200, body: multi_model_response.to_json)
    end

    it 'returns all models' do
      expect(described_class.model_names).to eq(%w[qwen3.6-27b llama-70b])
    end

    it 'returns correct max_context per model' do
      expect(described_class.max_context('qwen3.6-27b')).to eq(32_768)
      expect(described_class.max_context('llama-70b')).to eq(131_072)
    end
  end
end
