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
    Legion::LLM::Call::Registry.reset!
    Legion::Settings[:llm][:provider_layer] = {
      mode:             'auto',
      native_providers: %w[
        ollama vllm anthropic openai gemini mlx
        bedrock azure_foundry vertex claude
      ]
    }
  end

  describe 'auto mode (default)' do
    it 'reports auto as the default mode' do
      layer = Legion::LLM.settings[:provider_layer]
      expect(layer[:mode]).to eq('auto')
    end

    it 'uses Legion::LLM::Call::Dispatch when provider is registered in auto mode' do
      Legion::LLM::Call::Registry.register(:anthropic, fake_ext)
      expect(Legion::LLM::Call::Dispatch.available?(:anthropic)).to be true
    end

    it 'includes expected default keys' do
      layer = Legion::LLM.settings[:provider_layer]
      expect(layer).to have_key(:mode)
      expect(layer).to have_key(:native_providers)
    end

    it 'lists new lex-llm providers as default native_providers' do
      layer = Legion::LLM.settings[:provider_layer]
      expect(layer[:native_providers]).to include(
        'ollama', 'vllm', 'anthropic', 'openai', 'gemini', 'mlx',
        'bedrock', 'azure_foundry', 'vertex'
      )
    end
  end

  describe 'auto mode' do
    before do
      Legion::Settings[:llm][:provider_layer] = {
        mode:             'auto',
        native_providers: %w[claude bedrock]
      }
    end

    it 'reports auto mode in settings' do
      expect(Legion::LLM.settings.dig(:provider_layer, :mode)).to eq('auto')
    end

    it 'reports registered provider as available' do
      Legion::LLM::Call::Registry.register(:claude, fake_ext)
      expect(Legion::LLM::Call::Dispatch.available?(:claude)).to be true
    end

    it 'reports unregistered provider as unavailable' do
      expect(Legion::LLM::Call::Dispatch.available?(:bedrock)).to be false
    end
  end

  describe 'native mode' do
    before do
      Legion::Settings[:llm][:provider_layer] = {
        mode:             'native',
        native_providers: %w[claude bedrock]
      }
    end

    it 'reports native mode in settings' do
      expect(Legion::LLM.settings.dig(:provider_layer, :mode)).to eq('native')
    end

    it 'allows Legion::LLM::Call::Dispatch when provider is registered' do
      Legion::LLM::Call::Registry.register(:claude, fake_ext)
      result = Legion::LLM::Call::Dispatch.dispatch_chat(
        provider: :claude,
        model:    'claude-sonnet-4-6',
        messages: [{ role: 'user', content: 'hi' }]
      )
      expect(result[:result]).to eq('native response')
    end

    it 'raises ProviderError when provider is not registered and fallback disabled' do
      expect do
        Legion::LLM::Call::Dispatch.dispatch_chat(
          provider: :unregistered,
          model:    'some-model',
          messages: []
        )
      end.to raise_error(Legion::LLM::ProviderError)
    end
  end

  describe 'ProviderRegistry interaction' do
    it 'starts empty before any registration' do
      expect(Legion::LLM::Call::Registry.available).to be_empty
    end

    it 'registers and retrieves multiple providers' do
      ext_b = Module.new
      Legion::LLM::Call::Registry.register(:claude, fake_ext)
      Legion::LLM::Call::Registry.register(:bedrock, ext_b)
      expect(Legion::LLM::Call::Registry.available).to contain_exactly(:claude, :bedrock)
    end

    it 'resets registry cleanly' do
      Legion::LLM::Call::Registry.register(:claude, fake_ext)
      Legion::LLM::Call::Registry.reset!
      expect(Legion::LLM::Call::Registry.available).to be_empty
    end
  end
end
