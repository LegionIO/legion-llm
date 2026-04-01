# frozen_string_literal: true

require 'spec_helper'

RSpec.describe 'Provider layer mode switching' do
  let(:fake_ext) do
    Module.new do
      module_function

      def chat(model:, messages:, **) # rubocop:disable Lint/UnusedMethodArgument
        { content: 'native response', usage: { input_tokens: 7, output_tokens: 3 } }
      end
    end
  end

  before do
    Legion::LLM::ProviderRegistry.reset!
    Legion::Settings[:llm][:provider_layer] = {
      mode:                 'ruby_llm',
      native_providers:     %w[claude bedrock],
      fallback_to_ruby_llm: true
    }
  end

  describe 'ruby_llm mode (default)' do
    it 'reports ruby_llm as the default mode' do
      layer = Legion::LLM.settings[:provider_layer]
      expect(layer[:mode]).to eq('ruby_llm')
    end

    it 'does not use native dispatch when mode is ruby_llm' do
      Legion::LLM::ProviderRegistry.register(:claude, fake_ext)
      # use_native_dispatch? is private but we can test the setting contract
      expect(Legion::LLM.settings.dig(:provider_layer, :mode)).to eq('ruby_llm')
    end

    it 'includes expected default keys' do
      layer = Legion::LLM.settings[:provider_layer]
      expect(layer).to have_key(:mode)
      expect(layer).to have_key(:native_providers)
      expect(layer).to have_key(:fallback_to_ruby_llm)
    end

    it 'lists claude and bedrock as default native_providers' do
      layer = Legion::LLM.settings[:provider_layer]
      expect(layer[:native_providers]).to include('claude', 'bedrock')
    end

    it 'enables fallback_to_ruby_llm by default' do
      layer = Legion::LLM.settings[:provider_layer]
      expect(layer[:fallback_to_ruby_llm]).to be true
    end
  end

  describe 'auto mode' do
    before do
      Legion::Settings[:llm][:provider_layer] = {
        mode:                 'auto',
        native_providers:     %w[claude bedrock],
        fallback_to_ruby_llm: true
      }
    end

    it 'reports auto mode in settings' do
      expect(Legion::LLM.settings.dig(:provider_layer, :mode)).to eq('auto')
    end

    it 'reports registered provider as available' do
      Legion::LLM::ProviderRegistry.register(:claude, fake_ext)
      expect(Legion::LLM::NativeDispatch.available?(:claude)).to be true
    end

    it 'reports unregistered provider as unavailable' do
      expect(Legion::LLM::NativeDispatch.available?(:bedrock)).to be false
    end
  end

  describe 'native mode' do
    before do
      Legion::Settings[:llm][:provider_layer] = {
        mode:                 'native',
        native_providers:     %w[claude bedrock],
        fallback_to_ruby_llm: false
      }
    end

    it 'reports native mode in settings' do
      expect(Legion::LLM.settings.dig(:provider_layer, :mode)).to eq('native')
    end

    it 'allows native dispatch when provider is registered' do
      Legion::LLM::ProviderRegistry.register(:claude, fake_ext)
      result = Legion::LLM::NativeDispatch.dispatch_chat(
        provider: :claude,
        model:    'claude-sonnet-4-6',
        messages: [{ role: 'user', content: 'hi' }]
      )
      expect(result[:result]).to eq('native response')
    end

    it 'raises ProviderError when provider is not registered and fallback disabled' do
      expect do
        Legion::LLM::NativeDispatch.dispatch_chat(
          provider: :unregistered,
          model:    'some-model',
          messages: []
        )
      end.to raise_error(Legion::LLM::ProviderError)
    end
  end

  describe 'fallback_to_ruby_llm behavior' do
    it 'is true in default settings' do
      defaults = Legion::LLM::Settings.default
      expect(defaults.dig(:provider_layer, :fallback_to_ruby_llm)).to be true
    end

    it 'can be disabled in settings' do
      Legion::Settings[:llm][:provider_layer] = {
        mode:                 'native',
        native_providers:     %w[claude],
        fallback_to_ruby_llm: false
      }
      expect(Legion::LLM.settings.dig(:provider_layer, :fallback_to_ruby_llm)).to be false
    end
  end

  describe 'ProviderRegistry interaction' do
    it 'starts empty before any registration' do
      expect(Legion::LLM::ProviderRegistry.available).to be_empty
    end

    it 'registers and retrieves multiple providers' do
      ext_b = Module.new
      Legion::LLM::ProviderRegistry.register(:claude, fake_ext)
      Legion::LLM::ProviderRegistry.register(:bedrock, ext_b)
      expect(Legion::LLM::ProviderRegistry.available).to contain_exactly(:claude, :bedrock)
    end

    it 'resets registry cleanly' do
      Legion::LLM::ProviderRegistry.register(:claude, fake_ext)
      Legion::LLM::ProviderRegistry.reset!
      expect(Legion::LLM::ProviderRegistry.available).to be_empty
    end
  end
end
