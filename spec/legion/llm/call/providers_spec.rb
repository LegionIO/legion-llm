# frozen_string_literal: true

require 'spec_helper'
require 'legion/extensions/llm'

RSpec.describe Legion::LLM::Call::Providers do
  let(:provider_class) { Class.new }

  let(:provider_module) do
    klass = provider_class
    Module.new do
      const_set(:PROVIDER_FAMILY, :fake_provider)

      define_singleton_method(:provider_class) { klass }
      define_singleton_method(:provider_aliases) { [:fake_alias] }
      define_singleton_method(:discover_instances) do
        {
          local: {
            base_url:     'http://localhost:11434',
            tier:         :local,
            capabilities: %i[chat embed]
          }
        }
      end
    end
  end

  before do
    stub_const('Legion::Extensions::Llm::FakeProviderForSpec', provider_module)
    Legion::LLM::Call::Registry.reset!
  end

  it 'rebuilds provider registry entries from loaded lex-llm modules after the registry is cleared' do
    described_class.rediscover_all_providers
    Legion::LLM::Call::Registry.reset!

    described_class.rediscover_all_providers

    expect(Legion::LLM::Call::Registry.registered?(:fake_provider, instance: :local)).to be true
    expect(Legion::LLM::Call::Registry.registered?(:fake_alias, instance: :local)).to be true
  end

  it 'creates adapters and metadata from discovered provider instances' do
    described_class.rediscover_all_providers

    adapter = Legion::LLM::Call::Registry.for(:fake_provider, instance: :local)
    metadata = Legion::LLM::Call::Registry.metadata_for(:fake_provider, :local)

    expect(adapter).to be_a(Legion::LLM::Call::LexLLMAdapter)
    expect(adapter.instance_variable_get(:@instance_config)).to eq(
      base_url:    'http://localhost:11434',
      instance_id: :local
    )
    expect(metadata).to eq(tier: :local, capabilities: %i[chat embed])
  end

  it 'removes stale registry entries when a loaded provider no longer discovers instances' do
    Legion::LLM::Call::Registry.register(:fake_provider, Module.new, instance: :stale)
    allow(provider_module).to receive(:discover_instances).and_return({})

    described_class.rediscover_all_providers

    expect(Legion::LLM::Call::Registry.registered?(:fake_provider, instance: :stale)).to be false
  end
end
