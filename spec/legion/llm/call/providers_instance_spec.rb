# frozen_string_literal: true

require 'spec_helper'

RSpec.describe 'Provider instance registration', :provider_instances do
  before { Legion::LLM::Call::Registry.reset! }

  # Stub the lex-llm provider namespace
  let(:fake_config_class) do
    Class.new do
      attr_accessor :ollama_api_base, :ollama_api_key

      def respond_to?(method, include_all = false) # rubocop:disable Style/OptionalBooleanParameter
        %w[ollama_api_base= ollama_api_key=].include?(method.to_s) || super
      end
    end
  end

  let(:fake_provider_class) do
    Class.new do
      def self.configuration_options
        %i[ollama_api_base ollama_api_key]
      end

      def self.configured?(_config)
        true
      end

      def initialize(_config); end

      def complete(_messages, **); end
    end
  end

  let(:fake_namespace) do
    config_klass = fake_config_class
    provider_klass = fake_provider_class
    ns = Module.new
    ns.define_singleton_method(:config) { @config ||= config_klass.new }
    ns.const_set(:Configuration, config_klass)
    ns.const_set(:Provider, Module.new)
    ns.const_get(:Provider).define_singleton_method(:providers) { { ollama: provider_klass } }
    ns
  end

  before do
    stub_const('Legion::Extensions::Llm', fake_namespace)
    stub_const('Legion::Extensions::Llm::Provider', fake_namespace.const_get(:Provider))
  end

  describe '.register_instances' do
    it 'registers separate instances from settings with instances key' do
      provider_config = {
        enabled:   true,
        base_url:  'http://default:11434',
        instances: {
          local:  { base_url: 'http://localhost:11434' },
          apollo: { base_url: 'http://10.11.164.92:11434' }
        }
      }

      Legion::LLM::Call::Providers.register_instances(:ollama, provider_config)

      expect(Legion::LLM::Call::Registry.registered?(:ollama, instance: :local)).to be true
      expect(Legion::LLM::Call::Registry.registered?(:ollama, instance: :apollo)).to be true
    end

    it 'creates synthetic default instance when no instances key' do
      provider_config = {
        enabled:  true,
        base_url: 'http://localhost:11434'
      }

      Legion::LLM::Call::Providers.register_instances(:ollama, provider_config)

      expect(Legion::LLM::Call::Registry.registered?(:ollama, instance: :default)).to be true
    end

    it 'creates synthetic default instance when instances key is empty' do
      provider_config = {
        enabled:   true,
        base_url:  'http://localhost:11434',
        instances: {}
      }

      Legion::LLM::Call::Providers.register_instances(:ollama, provider_config)

      expect(Legion::LLM::Call::Registry.registered?(:ollama, instance: :default)).to be true
    end

    it 'merges parent config into each instance config' do
      provider_config = {
        enabled:   true,
        api_key:   'shared-key',
        instances: {
          local:  { base_url: 'http://localhost:11434' },
          remote: { base_url: 'http://remote:11434', api_key: 'override-key' }
        }
      }

      Legion::LLM::Call::Providers.register_instances(:ollama, provider_config)

      # Both instances should be registered
      expect(Legion::LLM::Call::Registry.registered?(:ollama, instance: :local)).to be true
      expect(Legion::LLM::Call::Registry.registered?(:ollama, instance: :remote)).to be true
    end

    it 'does not register instances for non-existent provider class' do
      # Remove the provider from the fake registry
      fake_namespace.const_get(:Provider).define_singleton_method(:providers) { {} }

      provider_config = {
        enabled:  true,
        base_url: 'http://localhost:11434'
      }

      Legion::LLM::Call::Providers.register_instances(:nonexistent_provider, provider_config)

      expect(Legion::LLM::Call::Registry.available).to be_empty
    end
  end

  describe '.register_single_instance' do
    it 'creates a LexLLMAdapter and registers in Registry' do
      config = { base_url: 'http://localhost:11434' }

      Legion::LLM::Call::Providers.register_single_instance(:ollama, :local, config)

      expect(Legion::LLM::Call::Registry.registered?(:ollama, instance: :local)).to be true
      adapter = Legion::LLM::Call::Registry.for(:ollama, instance: :local)
      expect(adapter).to be_a(Legion::LLM::Call::LexLLMAdapter)
    end

    it 'does not raise when provider class is not found' do
      fake_namespace.const_get(:Provider).define_singleton_method(:providers) { {} }

      expect do
        Legion::LLM::Call::Providers.register_single_instance(:nonexistent, :default, {})
      end.not_to raise_error
    end

    it 'handles exceptions gracefully' do
      # Force an error by making the adapter constructor blow up
      allow(Legion::LLM::Call::LexLLMAdapter).to receive(:new).and_raise(StandardError, 'boom')

      expect do
        Legion::LLM::Call::Providers.register_single_instance(:ollama, :test, {})
      end.not_to raise_error
    end
  end

  describe '.map_settings_to_config_options' do
    it 'maps short settings keys to provider-specific config option names' do
      config = { base_url: 'http://localhost:11434' }

      mapped = Legion::LLM::Call::Providers.map_settings_to_config_options(:ollama, fake_provider_class, config)

      expect(mapped[:ollama_api_base]).to eq('http://localhost:11434')
    end

    it 'maps api_key to provider-prefixed option' do
      config = { api_key: 'test-key-123' }

      mapped = Legion::LLM::Call::Providers.map_settings_to_config_options(:ollama, fake_provider_class, config)

      expect(mapped[:ollama_api_key]).to eq('test-key-123')
    end

    it 'returns empty hash when no config values match' do
      config = { some_unknown_thing: 'value' }

      mapped = Legion::LLM::Call::Providers.map_settings_to_config_options(:ollama, fake_provider_class, config)

      expect(mapped).to eq({})
    end
  end

  describe '.resolve_lex_llm_provider_class' do
    it 'returns the provider class for a known provider family' do
      result = Legion::LLM::Call::Providers.resolve_lex_llm_provider_class(:ollama)

      expect(result).to eq(fake_provider_class)
    end

    it 'returns nil for an unknown provider family' do
      result = Legion::LLM::Call::Providers.resolve_lex_llm_provider_class(:nonexistent)

      expect(result).to be_nil
    end

    it 'handles string provider names' do
      result = Legion::LLM::Call::Providers.resolve_lex_llm_provider_class('ollama')

      expect(result).to eq(fake_provider_class)
    end
  end

  describe '.auto_register_lex_llm_providers' do
    before do
      # Prevent actual require calls
      allow(Legion::LLM::Call::Providers).to receive(:load_lex_llm_base).and_return(true)
      allow(Legion::LLM::Call::Providers).to receive(:load_optional_feature).and_return(true)
    end

    it 'registers instances from settings when instances key is present' do
      Legion::Settings[:llm][:providers][:ollama] = {
        enabled:   true,
        base_url:  'http://default:11434',
        instances: {
          local:  { base_url: 'http://localhost:11434' },
          remote: { base_url: 'http://10.11.164.92:11434' }
        }
      }

      Legion::LLM::Call::Providers.auto_register_lex_llm_providers

      expect(Legion::LLM::Call::Registry.registered?(:ollama, instance: :local)).to be true
      expect(Legion::LLM::Call::Registry.registered?(:ollama, instance: :remote)).to be true
    end

    it 'registers default instance when no instances key' do
      Legion::Settings[:llm][:providers][:ollama] = {
        enabled:  true,
        base_url: 'http://localhost:11434'
      }

      Legion::LLM::Call::Providers.auto_register_lex_llm_providers

      expect(Legion::LLM::Call::Registry.registered?(:ollama, instance: :default)).to be true
    end

    it 'skips disabled providers' do
      Legion::Settings[:llm][:providers][:ollama] = {
        enabled:  false,
        base_url: 'http://localhost:11434'
      }

      Legion::LLM::Call::Providers.auto_register_lex_llm_providers

      expect(Legion::LLM::Call::Registry.registered?(:ollama)).to be false
    end

    it 'skips non-hash provider configs' do
      Legion::Settings[:llm][:providers][:ollama] = 'not a hash'

      expect do
        Legion::LLM::Call::Providers.auto_register_lex_llm_providers
      end.not_to raise_error
    end

    it 'does not call configure_lex_llm_provider (no global config mutation)' do
      Legion::Settings[:llm][:providers][:ollama] = {
        enabled:  true,
        base_url: 'http://localhost:11434'
      }

      expect(Legion::LLM::Call::Providers).not_to receive(:configure_lex_llm_provider)

      Legion::LLM::Call::Providers.auto_register_lex_llm_providers
    end

    it 'also registers :claude alias when anthropic provider has instances' do
      anthropic_class = Class.new do
        def self.configuration_options = %i[anthropic_api_key]
        def self.configured?(_config) = true
        def initialize(_config); end
      end

      pclass = fake_provider_class
      fake_namespace.const_get(:Provider).define_singleton_method(:providers) do
        { ollama: pclass, anthropic: anthropic_class }
      end

      Legion::Settings[:llm][:providers][:anthropic] = {
        enabled: true,
        api_key: 'test-key'
      }

      Legion::LLM::Call::Providers.auto_register_lex_llm_providers

      expect(Legion::LLM::Call::Registry.registered?(:anthropic)).to be true
      expect(Legion::LLM::Call::Registry.registered?(:claude)).to be true
    end
  end
end
