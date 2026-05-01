# frozen_string_literal: true

require 'spec_helper'
require 'legion/llm/discovery/memory_gate'
require 'legion/llm/discovery/ollama'
require 'legion/llm/discovery/system'

RSpec.describe Legion::LLM::Discovery::MemoryGate do
  before do
    Legion::LLM::Discovery::Ollama.reset!
    Legion::LLM::Discovery::System.reset!
  end

  describe '.allow?' do
    context 'with cloud providers (not in LOCAL_PROVIDERS)' do
      %i[bedrock anthropic openai gemini azure].each do |provider|
        it "returns true for #{provider} regardless of memory" do
          expect(described_class.allow?(provider: provider, model: 'any-model')).to be true
        end
      end
    end

    context 'with fleet-tier provider vllm (not in LOCAL_PROVIDERS)' do
      it 'returns true for vllm' do
        expect(described_class.allow?(provider: :vllm, model: 'qwen3.6-27b')).to be true
      end
    end

    context 'with local provider ollama' do
      before do
        allow(Legion::LLM::Discovery::System).to receive(:available_memory_mb).and_return(16_384)
      end

      it 'returns true when model fits in memory' do
        # Model is 4GB on disk, overhead 1.4x -> ~5600 MB cost + 2048 floor = 7648, available 16384
        allow(Legion::LLM::Discovery::Ollama).to receive(:model_size).with('llama3:latest').and_return(4_000_000_000)
        expect(described_class.allow?(provider: :ollama, model: 'llama3:latest')).to be true
      end

      it 'returns false when model exceeds available memory' do
        # Model is 12GB on disk -> 12000 MB * 1.4 = 16800 cost + 2048 floor = 18848, available 16384
        allow(Legion::LLM::Discovery::Ollama).to receive(:model_size).with('llama3:70b').and_return(12_000_000_000)
        expect(described_class.allow?(provider: :ollama, model: 'llama3:70b')).to be false
      end

      it 'returns true when model size is unknown (defaults to 4096 cost)' do
        # Unknown model -> cost 4096, floor 2048, total 6144, available 16384
        allow(Legion::LLM::Discovery::Ollama).to receive(:model_size).and_return(nil)
        expect(described_class.allow?(provider: :ollama, model: 'unknown-model')).to be true
      end
    end

    context 'with local provider mlx' do
      before do
        allow(Legion::LLM::Discovery::System).to receive(:available_memory_mb).and_return(16_384)
        allow(Legion::LLM::Discovery::Ollama).to receive(:model_size).and_return(nil)
      end

      it 'returns true when memory is sufficient' do
        # Unknown model -> cost 4096, floor 2048, total 6144, available 16384
        expect(described_class.allow?(provider: :mlx, model: 'some-mlx-model')).to be true
      end
    end

    context 'when memory cannot be queried' do
      it 'falls back to 4096 MB available (conservative default)' do
        allow(Legion::LLM::Discovery::System).to receive(:available_memory_mb).and_raise(StandardError, 'no memory info')
        allow(Legion::LLM::Discovery::Ollama).to receive(:model_size).and_return(nil)

        # fallback available = 4096, cost = 4096 (unknown model), floor = 2048
        # 4096 + 2048 = 6144 > 4096 -> should reject
        expect(described_class.allow?(provider: :ollama, model: 'some-model')).to be false
      end
    end
  end

  describe '.estimated_model_mb' do
    it 'applies overhead factor to model size in bytes' do
      allow(Legion::LLM::Discovery::Ollama).to receive(:model_size).with('llama3:latest').and_return(4_000_000_000)
      # 4_000_000_000 bytes -> 3814 MB (integer division), * 1.4 overhead = 5339.6 -> ceil = 5340
      result = described_class.estimated_model_mb('llama3:latest')
      expect(result).to eq((3814 * 1.4).ceil)
    end

    it 'returns 4096 default when model size is nil' do
      allow(Legion::LLM::Discovery::Ollama).to receive(:model_size).and_return(nil)
      expect(described_class.estimated_model_mb('unknown')).to eq(4096)
    end

    it 'returns 4096 default when model size is zero' do
      allow(Legion::LLM::Discovery::Ollama).to receive(:model_size).and_return(0)
      expect(described_class.estimated_model_mb('empty')).to eq(4096)
    end
  end

  describe '.memory_floor_mb' do
    it 'returns the configured value' do
      Legion::Settings[:llm][:discovery][:memory_floor_mb] = 4096
      expect(described_class.memory_floor_mb).to eq(4096)
    end

    it 'defaults to 2048 when not configured' do
      expect(described_class.memory_floor_mb).to eq(2048)
    end
  end
end
