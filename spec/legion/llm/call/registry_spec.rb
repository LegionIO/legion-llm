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

    it 'stores metadata alongside the adapter' do
      meta = { capabilities: [:chat], tier: :local }
      described_class.register(:ollama, adapter_a, metadata: meta)
      expect(described_class.metadata_for(:ollama)).to eq(meta)
    end

    it 'stores metadata for named instances' do
      meta_local = { capabilities: %i[chat embedding], url: 'http://localhost:11434' }
      meta_remote = { capabilities: [:chat], url: 'http://gpu-1:11434' }
      described_class.register(:ollama, adapter_a, instance: :local, metadata: meta_local)
      described_class.register(:ollama, adapter_b, instance: :remote, metadata: meta_remote)
      expect(described_class.metadata_for(:ollama, :local)).to eq(meta_local)
      expect(described_class.metadata_for(:ollama, :remote)).to eq(meta_remote)
    end

    it 'defaults metadata to empty hash when not provided' do
      described_class.register(:ollama, adapter_a)
      expect(described_class.metadata_for(:ollama)).to eq({})
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

    it 'returns the adapter, not the full entry hash' do
      described_class.register(:ollama, adapter_a, metadata: { capabilities: [:chat] })
      result = described_class.for(:ollama)
      expect(result).to eq(adapter_a)
      expect(result).not_to be_a(Hash)
    end
  end

  describe '.instances_for' do
    it 'returns all instances for a provider as { instance => adapter }' do
      described_class.register(:ollama, adapter_a, instance: :local)
      described_class.register(:ollama, adapter_b, instance: :apollo)
      instances = described_class.instances_for(:ollama)
      expect(instances).to eq(local: adapter_a, apollo: adapter_b)
    end

    it 'returns empty hash for unknown provider' do
      expect(described_class.instances_for(:nonexistent)).to eq({})
    end

    it 'returns adapters not entry hashes (backward compat)' do
      described_class.register(:ollama, adapter_a, instance: :local, metadata: { tier: :local })
      instances = described_class.instances_for(:ollama)
      expect(instances[:local]).to eq(adapter_a)
      expect(instances[:local]).not_to be_a(Hash)
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

  describe '.metadata_for' do
    it 'returns the stored metadata for a default instance' do
      meta = { capabilities: %i[chat embedding], tier: :local }
      described_class.register(:ollama, adapter_a, metadata: meta)
      expect(described_class.metadata_for(:ollama)).to eq(meta)
    end

    it 'returns the stored metadata for a named instance' do
      meta = { capabilities: [:chat], url: 'http://gpu-1:11434' }
      described_class.register(:ollama, adapter_a, instance: :remote, metadata: meta)
      expect(described_class.metadata_for(:ollama, :remote)).to eq(meta)
    end

    it 'returns empty hash for unregistered provider' do
      expect(described_class.metadata_for(:nonexistent)).to eq({})
    end

    it 'returns empty hash for unregistered instance' do
      described_class.register(:ollama, adapter_a, instance: :local)
      expect(described_class.metadata_for(:ollama, :remote)).to eq({})
    end
  end

  describe '.deregister_provider' do
    it 'removes all instances for a provider' do
      described_class.register(:ollama, adapter_a, instance: :local)
      described_class.register(:ollama, adapter_b, instance: :remote)
      described_class.register(:vllm, adapter_c)

      described_class.deregister_provider(:ollama)

      expect(described_class.registered?(:ollama)).to be false
      expect(described_class.for(:ollama)).to be_nil
      expect(described_class.available).to eq([:vllm])
    end

    it 'returns the count of removed instances' do
      described_class.register(:ollama, adapter_a, instance: :local)
      described_class.register(:ollama, adapter_b, instance: :remote)
      count = described_class.deregister_provider(:ollama)
      expect(count).to eq(2)
    end

    it 'returns 0 for an unregistered provider' do
      count = described_class.deregister_provider(:nonexistent)
      expect(count).to eq(0)
    end

    it 'does not affect other providers' do
      described_class.register(:ollama, adapter_a)
      described_class.register(:vllm, adapter_b)
      described_class.deregister_provider(:ollama)
      expect(described_class.for(:vllm)).to eq(adapter_b)
    end
  end

  describe '.with_capability' do
    before do
      described_class.register(:ollama, adapter_a, instance: :local,
                                                   metadata: { capabilities: %i[chat embedding] })
      described_class.register(:ollama, adapter_b, instance: :remote,
                                                   metadata: { capabilities: [:chat] })
      described_class.register(:vllm, adapter_c, metadata: { capabilities: %i[chat embedding structured] })
    end

    it 'returns only instances with the requested capability' do
      results = described_class.with_capability(:embedding)
      expect(results.size).to eq(2)
      providers = results.map { |r| [r[:provider], r[:instance]] }
      expect(providers).to contain_exactly(%i[ollama local], %i[vllm default])
    end

    it 'returns entries with provider, instance, adapter, and metadata keys' do
      results = described_class.with_capability(:chat)
      expect(results).to all(include(:provider, :instance, :adapter, :metadata))
    end

    it 'returns the adapter module in each entry' do
      results = described_class.with_capability(:structured)
      expect(results.size).to eq(1)
      expect(results.first[:adapter]).to eq(adapter_c)
    end

    it 'returns empty array when no instances have the capability' do
      expect(described_class.with_capability(:vision)).to eq([])
    end

    it 'handles instances without capabilities metadata' do
      described_class.register(:bedrock, adapter_a, metadata: { tier: :cloud })
      expect(described_class.with_capability(:chat)).not_to include(
        a_hash_including(provider: :bedrock)
      )
    end

    it 'coerces string capability to symbol' do
      results = described_class.with_capability('embedding')
      expect(results.size).to eq(2)
    end
  end

  describe '.all_instances' do
    it 'returns all registered instances across all providers' do
      described_class.register(:ollama, adapter_a, instance: :local, metadata: { tier: :local })
      described_class.register(:ollama, adapter_b, instance: :remote, metadata: { tier: :fleet })
      described_class.register(:vllm, adapter_c, metadata: { tier: :fleet })

      results = described_class.all_instances
      expect(results.size).to eq(3)
    end

    it 'returns entries with provider, instance, adapter, and metadata keys' do
      described_class.register(:ollama, adapter_a)
      results = described_class.all_instances
      expect(results.first).to include(:provider, :instance, :adapter, :metadata)
    end

    it 'includes correct data in each entry' do
      meta = { capabilities: [:chat] }
      described_class.register(:ollama, adapter_a, instance: :local, metadata: meta)
      results = described_class.all_instances
      expect(results.first).to eq(provider: :ollama, instance: :local, adapter: adapter_a, metadata: meta)
    end

    it 'returns empty array when nothing registered' do
      expect(described_class.all_instances).to eq([])
    end
  end

  describe '.providers' do
    it 'returns the registry hash keyed by provider symbol' do
      described_class.register(:ollama, adapter_a, instance: :local)
      described_class.register(:vllm, adapter_b)
      result = described_class.providers
      expect(result.keys).to contain_exactly(:ollama, :vllm)
    end

    it 'returns a frozen hash' do
      described_class.register(:anthropic, adapter_a)
      expect(described_class.providers).to be_frozen
    end

    it 'returns empty hash when nothing registered' do
      expect(described_class.providers).to eq({})
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

    it 'clears metadata' do
      described_class.register(:ollama, adapter_a, metadata: { capabilities: [:chat] })
      described_class.reset!
      expect(described_class.metadata_for(:ollama)).to eq({})
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
