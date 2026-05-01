# frozen_string_literal: true

require 'spec_helper'
require 'legion/llm/discovery/vllm'

RSpec.describe Legion::LLM::Discovery::Vllm, 'per-instance scanning' do
  before { described_class.reset! }

  let(:gpu1_models) do
    {
      'data' => [
        { 'id' => 'qwen3.6-27b', 'max_model_len' => 32_768, 'owned_by' => 'vllm' }
      ]
    }
  end

  let(:gpu2_models) do
    {
      'data' => [
        { 'id' => 'llama-70b', 'max_model_len' => 131_072, 'owned_by' => 'vllm' },
        { 'id' => 'codestral-25.01', 'max_model_len' => 65_536, 'owned_by' => 'vllm' }
      ]
    }
  end

  context 'with multi-instance settings' do
    before do
      Legion::Settings[:llm][:providers][:vllm] = {
        enabled:   true,
        instances: {
          gpu1: { base_url: 'http://gpu1:8000/v1' },
          gpu2: { base_url: 'http://gpu2:8000/v1' }
        }
      }

      stub_request(:get, 'http://gpu1:8000/v1/models')
        .to_return(status: 200, body: gpu1_models.to_json)
      stub_request(:get, 'http://gpu2:8000/v1/models')
        .to_return(status: 200, body: gpu2_models.to_json)
    end

    describe '.scan_all_instances' do
      it 'returns per-instance model data' do
        result = described_class.scan_all_instances
        expect(result.keys).to contain_exactly(:gpu1, :gpu2)
        expect(result[:gpu1][:models].size).to eq(1)
        expect(result[:gpu2][:models].size).to eq(2)
        expect(result[:gpu1][:base_url]).to eq('http://gpu1:8000/v1')
        expect(result[:gpu2][:base_url]).to eq('http://gpu2:8000/v1')
      end

      it 'includes correct model ids per instance' do
        result = described_class.scan_all_instances
        gpu1_names = result[:gpu1][:models].map { |m| m[:id] }
        gpu2_names = result[:gpu2][:models].map { |m| m[:id] }
        expect(gpu1_names).to eq(['qwen3.6-27b'])
        expect(gpu2_names).to eq(['llama-70b', 'codestral-25.01'])
      end
    end

    describe '.model_available? with instance:' do
      it 'returns true when model exists on the specified instance' do
        described_class.refresh!
        expect(described_class.model_available?('llama-70b', instance: :gpu2)).to be true
      end

      it 'returns false when model is not on the specified instance' do
        described_class.refresh!
        expect(described_class.model_available?('llama-70b', instance: :gpu1)).to be false
      end

      it 'checks all instances when instance: nil' do
        described_class.refresh!
        expect(described_class.model_available?('llama-70b')).to be true
        expect(described_class.model_available?('qwen3.6-27b')).to be true
      end
    end

    describe '.models_for' do
      it 'returns models for a specific instance' do
        described_class.refresh!
        gpu2 = described_class.models_for(instance: :gpu2)
        expect(gpu2.size).to eq(2)
        expect(gpu2.map { |m| m[:id] }).to include('llama-70b')
      end

      it 'returns empty array for unknown instance' do
        described_class.refresh!
        expect(described_class.models_for(instance: :nonexistent)).to eq([])
      end

      it 'accepts string instance keys' do
        described_class.refresh!
        expect(described_class.models_for(instance: 'gpu1').size).to eq(1)
      end
    end

    describe '.max_context with instance:' do
      it 'returns max_model_len for a model on a specific instance' do
        described_class.refresh!
        expect(described_class.max_context('llama-70b', instance: :gpu2)).to eq(131_072)
      end

      it 'returns nil when model is not on the specified instance' do
        described_class.refresh!
        expect(described_class.max_context('llama-70b', instance: :gpu1)).to be_nil
      end

      it 'searches all instances when instance: nil' do
        described_class.refresh!
        expect(described_class.max_context('llama-70b')).to eq(131_072)
      end
    end

    describe '.healthy? with instance:' do
      it 'checks health for a specific instance' do
        stub_request(:get, 'http://gpu1:8000/health').to_return(status: 200)
        expect(described_class.healthy?(instance: :gpu1)).to be true
      end

      it 'returns false for unhealthy instance' do
        stub_request(:get, 'http://gpu2:8000/health').to_return(status: 503)
        expect(described_class.healthy?(instance: :gpu2)).to be false
      end

      it 'checks any instance when instance: nil' do
        stub_request(:get, 'http://gpu1:8000/health').to_return(status: 200)
        stub_request(:get, 'http://gpu2:8000/health').to_return(status: 503)
        expect(described_class.healthy?).to be true
      end
    end

    describe '.models (backward compat)' do
      it 'returns all models across instances deduplicated' do
        described_class.refresh!
        names = described_class.model_names
        expect(names).to include('qwen3.6-27b', 'llama-70b', 'codestral-25.01')
        expect(names.size).to eq(3)
      end
    end

    describe '.refresh!' do
      it 'refreshes all instances' do
        described_class.refresh!
        expect(described_class.model_names.size).to eq(3)
        expect(a_request(:get, 'http://gpu1:8000/v1/models')).to have_been_made
        expect(a_request(:get, 'http://gpu2:8000/v1/models')).to have_been_made
      end
    end

    context 'when one instance is unreachable' do
      before do
        described_class.reset!
        stub_request(:get, 'http://gpu2:8000/v1/models').to_timeout
      end

      it 'still returns models from the reachable instance' do
        described_class.refresh!
        expect(described_class.models_for(instance: :gpu1).size).to eq(1)
        expect(described_class.models_for(instance: :gpu2)).to eq([])
      end
    end
  end

  context 'with flat config (no instances key)' do
    before do
      Legion::Settings[:llm][:providers][:vllm] = {
        enabled:  true,
        base_url: 'http://gpu-server:8000/v1'
      }
      stub_request(:get, 'http://gpu-server:8000/v1/models')
        .to_return(status: 200, body: gpu1_models.to_json)
    end

    it 'uses synthetic :default instance' do
      result = described_class.scan_all_instances
      expect(result.keys).to eq([:default])
      expect(result[:default][:models].size).to eq(1)
      expect(result[:default][:base_url]).to eq('http://gpu-server:8000/v1')
    end

    it 'backward compat: models returns all models' do
      expect(described_class.models.size).to eq(1)
    end

    it 'backward compat: model_available? works without instance:' do
      expect(described_class.model_available?('qwen3.6-27b')).to be true
    end

    it 'models_for with :default returns the models' do
      described_class.refresh!
      expect(described_class.models_for(instance: :default).size).to eq(1)
    end
  end

  context 'deduplication across instances' do
    before do
      Legion::Settings[:llm][:providers][:vllm] = {
        enabled:   true,
        instances: {
          gpu1: { base_url: 'http://gpu1:8000/v1' },
          gpu2: { base_url: 'http://gpu2:8000/v1' }
        }
      }
      shared = { 'data' => [{ 'id' => 'qwen3.6-27b', 'max_model_len' => 32_768, 'owned_by' => 'vllm' }] }
      stub_request(:get, 'http://gpu1:8000/v1/models')
        .to_return(status: 200, body: shared.to_json)
      stub_request(:get, 'http://gpu2:8000/v1/models')
        .to_return(status: 200, body: shared.to_json)
    end

    it 'deduplicates models in the aggregate list' do
      described_class.refresh!
      expect(described_class.model_names).to eq(['qwen3.6-27b'])
      expect(described_class.models.size).to eq(1)
    end

    it 'each instance still has its own copy' do
      described_class.refresh!
      expect(described_class.models_for(instance: :gpu1).size).to eq(1)
      expect(described_class.models_for(instance: :gpu2).size).to eq(1)
    end
  end
end
