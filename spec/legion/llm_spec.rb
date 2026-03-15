# frozen_string_literal: true

require 'spec_helper'

RSpec.describe Legion::LLM do
  describe '.settings' do
    it 'returns default settings hash' do
      settings = described_class.settings
      expect(settings).to be_a(Hash)
      expect(settings[:enabled]).to be true
      expect(settings[:connected]).to be false
      expect(settings[:providers]).to be_a(Hash)
    end

    it 'includes all provider configs' do
      providers = described_class.settings[:providers]
      expect(providers.keys).to include(:bedrock, :anthropic, :openai, :gemini, :ollama)
    end

    it 'defaults bedrock region to us-east-2' do
      expect(described_class.settings[:providers][:bedrock][:region]).to eq('us-east-2')
    end
  end

  describe '.start and .shutdown' do
    before do
      Legion::Settings[:llm][:providers][:ollama][:enabled] = true
      allow(described_class).to receive(:ping_provider)
    end

    it 'marks connected on start' do
      described_class.start
      expect(described_class.started?).to be true
      expect(Legion::Settings[:llm][:connected]).to be true
    end

    it 'marks disconnected on shutdown' do
      described_class.start
      described_class.shutdown
      expect(described_class.started?).to be false
      expect(Legion::Settings[:llm][:connected]).to be false
    end
  end

  describe '.chat' do
    it 'returns a RubyLLM::Chat instance' do
      fake_chat = instance_double(RubyLLM::Chat)
      allow(RubyLLM).to receive(:chat).with(model: 'gpt-4o', provider: :openai).and_return(fake_chat)
      chat = described_class.chat(model: 'gpt-4o', provider: :openai)
      expect(chat).to be(fake_chat)
    end
  end

  describe 'auto_configure_defaults' do
    before { allow(described_class).to receive(:ping_provider) }

    it 'picks bedrock when bedrock is the first enabled provider' do
      Legion::Settings[:llm][:providers][:bedrock][:enabled] = true
      described_class.start
      expect(Legion::Settings[:llm][:default_provider]).to eq(:bedrock)
    end

    it 'picks anthropic when only anthropic is enabled' do
      Legion::Settings[:llm][:providers][:anthropic][:enabled] = true
      described_class.start
      expect(Legion::Settings[:llm][:default_provider]).to eq(:anthropic)
    end

    it 'respects explicit default_model setting' do
      Legion::Settings[:llm][:default_model] = 'custom-model'
      Legion::Settings[:llm][:default_provider] = :openai
      described_class.start
      expect(Legion::Settings[:llm][:default_model]).to eq('custom-model')
    end
  end

  describe Legion::LLM::Settings do
    describe '.default' do
      it 'returns a hash with expected keys' do
        defaults = described_class.default
        expect(defaults).to include(:enabled, :connected, :default_model, :default_provider, :providers)
      end
    end

    describe '.providers' do
      it 'all providers default to disabled' do
        described_class.providers.each_value do |config|
          expect(config[:enabled]).to be false
        end
      end
    end
  end

  describe Legion::LLM::Providers do
    let(:test_class) do
      Class.new do
        extend Legion::LLM::Providers

        def self.settings
          Legion::Settings[:llm]
        end
      end
    end

    describe '#vault_available?' do
      it 'returns false when Vault is not connected' do
        Legion::Settings.merge_settings('crypt', { vault: { connected: false } })
        expect(test_class.vault_available?).to be false
      end
    end

    describe '#configure_bedrock' do
      it 'configures with SigV4 when api_key and secret_key are present' do
        test_class.send(:configure_bedrock, {
                          api_key: 'AKID', secret_key: 'SECRET', region: 'us-east-2'
                        })
        expect(RubyLLM.config.bedrock_api_key).to eq('AKID')
        expect(RubyLLM.config.bedrock_secret_key).to eq('SECRET')
      end

      it 'configures with bearer token when bearer_token is present' do
        test_class.send(:configure_bedrock, {
                          bearer_token: 'my-bearer-token', region: 'us-east-2'
                        })
        expect(RubyLLM.config.bedrock_bearer_token).to eq('my-bearer-token')
        expect(RubyLLM.config.bedrock_region).to eq('us-east-2')
      end

      it 'skips config when no credentials are provided' do
        RubyLLM.config.bedrock_api_key = nil
        RubyLLM.config.bedrock_bearer_token = nil
        test_class.send(:configure_bedrock, { region: 'us-east-2' })
        expect(RubyLLM.config.bedrock_api_key).to be_nil
        expect(RubyLLM.config.bedrock_bearer_token).to be_nil
      end
    end
  end

  describe 'Bedrock bearer auth monkey patch' do
    before do
      require 'legion/llm/bedrock_bearer_auth'
    end

    it 'adds bedrock_bearer_token accessor to Configuration' do
      expect(RubyLLM::Configuration.instance_methods).to include(:bedrock_bearer_token, :bedrock_bearer_token=)
    end

    it 'changes configuration_requirements when bearer token is set' do
      RubyLLM.config.bedrock_bearer_token = 'test-token'
      reqs = RubyLLM::Providers::Bedrock.configuration_requirements
      expect(reqs).to eq(%i[bedrock_bearer_token bedrock_region])
    end

    it 'keeps SigV4 requirements when no bearer token is set' do
      RubyLLM.config.bedrock_bearer_token = nil
      reqs = RubyLLM::Providers::Bedrock.configuration_requirements
      expect(reqs).to eq(%i[bedrock_api_key bedrock_secret_key bedrock_region])
    end

    after do
      RubyLLM.config.bedrock_bearer_token = nil
    end
  end
end
