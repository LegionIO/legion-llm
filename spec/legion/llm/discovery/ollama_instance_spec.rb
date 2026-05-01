# frozen_string_literal: true

require 'spec_helper'
require 'legion/llm/discovery/ollama'

RSpec.describe Legion::LLM::Discovery::Ollama, 'per-instance scanning' do
  before { described_class.reset! }

  let(:local_models) do
    {
      'models' => [
        { 'name' => 'qwen3.6:27b-q4_K_M', 'size' => 17_000_000_000 },
        { 'name' => 'llama3.1:8b', 'size' => 4_700_000_000 }
      ]
    }
  end

  let(:apollo_models) do
    {
      'models' => [
        { 'name' => 'mxbai-embed-large', 'size' => 669_000_000 },
        { 'name' => 'nomic-embed-text',  'size' => 274_000_000 }
      ]
    }
  end

  context 'with multi-instance settings' do
    before do
      Legion::Settings[:llm][:providers][:ollama] = {
        enabled:   true,
        instances: {
          local:  { base_url: 'http://127.0.0.1:11434' },
          apollo: { base_url: 'http://10.11.164.92:11434' }
        }
      }

      stub_request(:get, 'http://127.0.0.1:11434/api/tags')
        .to_return(status: 200, body: local_models.to_json)
      stub_request(:get, 'http://10.11.164.92:11434/api/tags')
        .to_return(status: 200, body: apollo_models.to_json)
    end

    describe '.scan_all_instances' do
      it 'returns per-instance model data' do
        result = described_class.scan_all_instances
        expect(result.keys).to contain_exactly(:local, :apollo)
        expect(result[:local][:models].size).to eq(2)
        expect(result[:apollo][:models].size).to eq(2)
        expect(result[:local][:base_url]).to eq('http://127.0.0.1:11434')
        expect(result[:apollo][:base_url]).to eq('http://10.11.164.92:11434')
      end

      it 'includes correct model names per instance' do
        result = described_class.scan_all_instances
        local_names = result[:local][:models].map { |m| m['name'] }
        apollo_names = result[:apollo][:models].map { |m| m['name'] }
        expect(local_names).to eq(['qwen3.6:27b-q4_K_M', 'llama3.1:8b'])
        expect(apollo_names).to eq(%w[mxbai-embed-large nomic-embed-text])
      end
    end

    describe '.model_available? with instance:' do
      it 'returns true when model exists on the specified instance' do
        described_class.refresh!
        expect(described_class.model_available?('mxbai-embed-large', instance: :apollo)).to be true
      end

      it 'returns false when model is not on the specified instance' do
        described_class.refresh!
        expect(described_class.model_available?('mxbai-embed-large', instance: :local)).to be false
      end

      it 'checks all instances when instance: nil' do
        described_class.refresh!
        expect(described_class.model_available?('mxbai-embed-large')).to be true
        expect(described_class.model_available?('qwen3.6:27b-q4_K_M')).to be true
      end

      it 'matches model name prefix for tagged models' do
        described_class.refresh!
        expect(described_class.model_available?('qwen3.6', instance: :local)).to be true
      end
    end

    describe '.models_for' do
      it 'returns models for a specific instance' do
        described_class.refresh!
        local = described_class.models_for(instance: :local)
        expect(local.size).to eq(2)
        expect(local.map { |m| m['name'] }).to include('llama3.1:8b')
      end

      it 'returns empty array for unknown instance' do
        described_class.refresh!
        expect(described_class.models_for(instance: :nonexistent)).to eq([])
      end

      it 'accepts string instance keys' do
        described_class.refresh!
        expect(described_class.models_for(instance: 'local').size).to eq(2)
      end
    end

    describe '.model_size with instance:' do
      it 'returns size for a model on a specific instance' do
        described_class.refresh!
        expect(described_class.model_size('mxbai-embed-large', instance: :apollo)).to eq(669_000_000)
      end

      it 'returns nil when model is not on the specified instance' do
        described_class.refresh!
        expect(described_class.model_size('mxbai-embed-large', instance: :local)).to be_nil
      end

      it 'searches all instances when instance: nil' do
        described_class.refresh!
        expect(described_class.model_size('mxbai-embed-large')).to eq(669_000_000)
      end
    end

    describe '.models (backward compat)' do
      it 'returns all models across instances deduplicated' do
        described_class.refresh!
        names = described_class.model_names
        expect(names).to include('qwen3.6:27b-q4_K_M', 'llama3.1:8b', 'mxbai-embed-large', 'nomic-embed-text')
        expect(names.size).to eq(4)
      end
    end

    describe '.refresh!' do
      it 'refreshes all instances' do
        described_class.refresh!
        expect(described_class.model_names.size).to eq(4)
        expect(a_request(:get, 'http://127.0.0.1:11434/api/tags')).to have_been_made
        expect(a_request(:get, 'http://10.11.164.92:11434/api/tags')).to have_been_made
      end
    end

    context 'when one instance is unreachable' do
      before do
        described_class.reset!
        stub_request(:get, 'http://10.11.164.92:11434/api/tags').to_timeout
      end

      it 'still returns models from the reachable instance' do
        described_class.refresh!
        expect(described_class.models_for(instance: :local).size).to eq(2)
        expect(described_class.models_for(instance: :apollo)).to eq([])
      end
    end
  end

  context 'with flat config (no instances key)' do
    before do
      Legion::Settings[:llm][:providers][:ollama] = {
        enabled:  true,
        base_url: 'http://localhost:11434'
      }
      stub_request(:get, 'http://localhost:11434/api/tags')
        .to_return(status: 200, body: local_models.to_json)
    end

    it 'uses synthetic :default instance' do
      result = described_class.scan_all_instances
      expect(result.keys).to eq([:default])
      expect(result[:default][:models].size).to eq(2)
      expect(result[:default][:base_url]).to eq('http://localhost:11434')
    end

    it 'backward compat: models returns all models' do
      expect(described_class.models.size).to eq(2)
    end

    it 'backward compat: model_available? works without instance:' do
      expect(described_class.model_available?('llama3.1:8b')).to be true
    end

    it 'models_for with :default returns the models' do
      described_class.refresh!
      expect(described_class.models_for(instance: :default).size).to eq(2)
    end
  end

  context 'deduplication across instances' do
    before do
      Legion::Settings[:llm][:providers][:ollama] = {
        enabled:   true,
        instances: {
          local:  { base_url: 'http://127.0.0.1:11434' },
          remote: { base_url: 'http://10.0.0.1:11434' }
        }
      }
      shared_models = { 'models' => [{ 'name' => 'llama3.1:8b', 'size' => 4_700_000_000 }] }
      stub_request(:get, 'http://127.0.0.1:11434/api/tags')
        .to_return(status: 200, body: shared_models.to_json)
      stub_request(:get, 'http://10.0.0.1:11434/api/tags')
        .to_return(status: 200, body: shared_models.to_json)
    end

    it 'deduplicates models in the aggregate list' do
      described_class.refresh!
      expect(described_class.model_names).to eq(['llama3.1:8b'])
      expect(described_class.models.size).to eq(1)
    end

    it 'each instance still has its own copy' do
      described_class.refresh!
      expect(described_class.models_for(instance: :local).size).to eq(1)
      expect(described_class.models_for(instance: :remote).size).to eq(1)
    end
  end
end
