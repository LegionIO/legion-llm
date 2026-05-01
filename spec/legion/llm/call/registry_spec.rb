# frozen_string_literal: true

require 'spec_helper'

RSpec.describe Legion::LLM::Call::Registry do
  before { described_class.reset! }

  let(:adapter_a) { Module.new { define_singleton_method(:name) { 'adapter_a' } } }
  let(:adapter_b) { Module.new { define_singleton_method(:name) { 'adapter_b' } } }
  let(:adapter_c) { Module.new { define_singleton_method(:name) { 'adapter_c' } } }

  describe '.register' do
    it 'registers with default instance when no instance given' do
      described_class.register(:ollama, adapter_a)
      expect(described_class.for(:ollama)).to eq(adapter_a)
    end

    it 'registers with a named instance' do
      described_class.register(:ollama, adapter_a, instance: :local)
      expect(described_class.for(:ollama, instance: :local)).to eq(adapter_a)
    end

    it 'returns the registered extension module' do
      result = described_class.register(:ollama, adapter_a)
      expect(result).to eq(adapter_a)
    end

    it 'coerces string names to symbols' do
      described_class.register('ollama', adapter_a, instance: 'local')
      expect(described_class.for(:ollama, instance: :local)).to eq(adapter_a)
    end
  end

  describe '.for' do
    context 'with default instance' do
      before { described_class.register(:ollama, adapter_a) }

      it 'returns the default instance when no instance specified' do
        expect(described_class.for(:ollama)).to eq(adapter_a)
      end

      it 'returns the default instance when instance: :default given explicitly' do
        expect(described_class.for(:ollama, instance: :default)).to eq(adapter_a)
      end
    end

    context 'with named instances' do
      before do
        described_class.register(:ollama, adapter_a, instance: :local)
        described_class.register(:ollama, adapter_b, instance: :apollo)
      end

      it 'returns the requested named instance' do
        expect(described_class.for(:ollama, instance: :local)).to eq(adapter_a)
        expect(described_class.for(:ollama, instance: :apollo)).to eq(adapter_b)
      end

      it 'returns nil for an unknown instance' do
        expect(described_class.for(:ollama, instance: :nonexistent)).to be_nil
      end
    end

    context 'with multiple instances of same provider' do
      it 'returns :default when it exists and no instance specified' do
        described_class.register(:ollama, adapter_a, instance: :default)
        described_class.register(:ollama, adapter_b, instance: :apollo)
        expect(described_class.for(:ollama)).to eq(adapter_a)
      end

      it 'returns first available when no :default and no instance specified' do
        described_class.register(:ollama, adapter_a, instance: :local)
        described_class.register(:ollama, adapter_b, instance: :apollo)
        expect(described_class.for(:ollama)).to eq(adapter_a)
      end
    end

    it 'returns nil for an unregistered provider' do
      expect(described_class.for(:nonexistent)).to be_nil
    end
  end

  describe '.instances_for' do
    it 'returns all instances for a provider' do
      described_class.register(:ollama, adapter_a, instance: :local)
      described_class.register(:ollama, adapter_b, instance: :apollo)
      instances = described_class.instances_for(:ollama)
      expect(instances).to eq(local: adapter_a, apollo: adapter_b)
    end

    it 'returns empty hash for unknown provider' do
      expect(described_class.instances_for(:nonexistent)).to eq({})
    end

    it 'returns a defensive copy' do
      described_class.register(:ollama, adapter_a, instance: :local)
      instances = described_class.instances_for(:ollama)
      instances[:injected] = adapter_b
      expect(described_class.instances_for(:ollama)).not_to have_key(:injected)
    end
  end

  describe '.available' do
    it 'returns provider family names, not instances' do
      described_class.register(:ollama, adapter_a, instance: :local)
      described_class.register(:ollama, adapter_b, instance: :apollo)
      described_class.register(:vllm, adapter_c)
      expect(described_class.available).to contain_exactly(:ollama, :vllm)
    end

    it 'returns empty array when nothing registered' do
      expect(described_class.available).to eq([])
    end
  end

  describe '.registered?' do
    before do
      described_class.register(:ollama, adapter_a, instance: :local)
    end

    it 'returns true when any instance exists for the family' do
      expect(described_class.registered?(:ollama)).to be true
    end

    it 'returns false for unregistered family' do
      expect(described_class.registered?(:nonexistent)).to be false
    end

    it 'returns true for a specific existing instance' do
      expect(described_class.registered?(:ollama, instance: :local)).to be true
    end

    it 'returns false for a specific non-existing instance' do
      expect(described_class.registered?(:ollama, instance: :apollo)).to be false
    end
  end

  describe '.reset!' do
    it 'clears all providers and instances' do
      described_class.register(:ollama, adapter_a, instance: :local)
      described_class.register(:vllm, adapter_b)
      described_class.reset!
      expect(described_class.available).to eq([])
      expect(described_class.for(:ollama)).to be_nil
      expect(described_class.for(:vllm)).to be_nil
    end
  end

  describe 'backward compatibility' do
    it 'works with the old 2-arg register and 1-arg for pattern' do
      described_class.register(:anthropic, adapter_a)
      expect(described_class.for(:anthropic)).to eq(adapter_a)
      expect(described_class.available).to include(:anthropic)
      expect(described_class.registered?(:anthropic)).to be true
    end

    it 'supports registering multiple different providers without instance' do
      described_class.register(:anthropic, adapter_a)
      described_class.register(:bedrock, adapter_b)
      expect(described_class.for(:anthropic)).to eq(adapter_a)
      expect(described_class.for(:bedrock)).to eq(adapter_b)
      expect(described_class.available).to contain_exactly(:anthropic, :bedrock)
    end
  end
end
