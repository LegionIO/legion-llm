# frozen_string_literal: true

begin
  require 'legion/extensions/llm'
  require 'legion/extensions/llm/provider' unless defined?(::Legion::Extensions::Llm::Provider)
rescue LoadError
  nil
end

RSpec.describe Legion::LLM::Providers do
  def lex_llm_test_namespace
    return ::Legion::Extensions::Llm if defined?(::Legion::Extensions::Llm::Provider)

    raise NameError, 'lex-llm provider namespace is not loaded'
  end

  let(:host) do
    Class.new do
      include Legion::LLM::Providers
      include Legion::Logging::Helper

      def settings
        Legion::LLM.settings
      end
    end.new
  end

  describe '#resolve_broker_credential' do
    context 'when Broker has a valid token' do
      before do
        broker = Module.new do
          def self.token_for(name, **_kwargs)
            name == :openai ? 'sk-broker-key' : nil
          end
        end
        stub_const('Legion::Identity::Broker', broker)
      end

      it 'returns the Broker token' do
        expect(host.send(:resolve_broker_credential, :openai)).to eq('sk-broker-key')
      end

      it 'returns nil for unregistered providers' do
        expect(host.send(:resolve_broker_credential, :unknown)).to be_nil
      end

      it 'includes audit purpose and context when resolving Broker credentials' do
        broker = Legion::Identity::Broker
        allow(broker).to receive(:token_for).and_call_original

        host.send(:resolve_broker_credential, :openai)

        expect(broker).to have_received(:token_for).with(
          :openai,
          purpose: 'llm.provider.credential',
          context: { provider: :openai }
        )
      end
    end

    context 'when Broker is not defined' do
      before { hide_const('Legion::Identity::Broker') }

      it 'returns nil' do
        expect(host.send(:resolve_broker_credential, :openai)).to be_nil
      end
    end

    context 'when Broker raises an error' do
      before do
        broker = Module.new do
          def self.token_for(_name, **_kwargs)
            raise StandardError, 'Broker unavailable'
          end
        end
        stub_const('Legion::Identity::Broker', broker)
      end

      it 'returns nil' do
        expect(host.send(:resolve_broker_credential, :openai)).to be_nil
      end
    end
  end

  describe '#configure_openai with Broker' do
    let(:ruby_llm_config) { double('config') }

    before do
      allow(RubyLLM).to receive(:configure).and_yield(ruby_llm_config)
      allow(ruby_llm_config).to receive(:openai_api_key=)
    end

    context 'when Broker has a credential' do
      before do
        broker = Module.new do
          def self.token_for(name, **_kwargs)
            name == :openai ? 'sk-broker-key' : nil
          end
        end
        stub_const('Legion::Identity::Broker', broker)
      end

      it 'uses the Broker credential over config' do
        host.send(:configure_openai, { api_key: 'sk-settings-key' })
        expect(ruby_llm_config).to have_received(:openai_api_key=).with('sk-broker-key')
      end
    end

    context 'when Broker returns nil' do
      before do
        broker = Module.new do
          def self.token_for(_name, **_kwargs) = nil
        end
        stub_const('Legion::Identity::Broker', broker)
      end

      it 'falls back to config api_key' do
        host.send(:configure_openai, { api_key: 'sk-settings-key' })
        expect(ruby_llm_config).to have_received(:openai_api_key=).with('sk-settings-key')
      end

      it 'falls back to string-keyed config api_key' do
        host.send(:configure_openai, { 'api_key' => 'sk-settings-key' })
        expect(ruby_llm_config).to have_received(:openai_api_key=).with('sk-settings-key')
      end
    end
  end

  describe '#configure_providers' do
    before do
      hide_const('Legion::Identity::Broker')
      allow(host).to receive(:auto_enable_from_resolved_credentials)
      allow(host).to receive(:apply_provider_config)
    end

    it 'iterates top-level string-keyed provider settings' do
      Legion::Settings[:llm]['providers'] = {
        'openai' => { 'enabled' => true, 'api_key' => 'sk-settings-key' }
      }

      host.send(:configure_providers)

      expect(host).to have_received(:apply_provider_config).with(
        'openai',
        { 'enabled' => true, 'api_key' => 'sk-settings-key' }
      )
    end
  end

  describe '#auto_register_lex_llm_providers' do
    before do
      namespace = lex_llm_test_namespace
      Legion::LLM::Call::Registry.reset!
      namespace::Provider.providers.clear
      provider_class = Class.new(namespace::Provider) { def api_base = 'https://provider.invalid' }
      namespace::Provider.register(:anthropic, provider_class)

      allow(host).to receive(:load_optional_feature).and_return(true)
    end

    after do
      lex_llm_test_namespace::Provider.providers.clear
      Legion::LLM::Call::Registry.reset!
    end

    it 'bridges registered lex-llm providers into the native registry' do
      host.send(:auto_register_lex_llm_providers)

      expect(Legion::LLM::Call::Registry.for(:anthropic)).to be_a(Legion::LLM::Call::LexLLMAdapter)
      expect(Legion::LLM::Call::Registry.for(:claude)).to be_a(Legion::LLM::Call::LexLLMAdapter)
    end

    it 'loads every provider gem wired by the LegionIO LLM setup pack' do
      host.send(:auto_register_lex_llm_providers)

      expect(host).to have_received(:load_optional_feature).with('legion/extensions/llm/ollama')
      expect(host).to have_received(:load_optional_feature).with('legion/extensions/llm/vllm')
      expect(host).to have_received(:load_optional_feature).with('legion/extensions/llm/anthropic')
      expect(host).to have_received(:load_optional_feature).with('legion/extensions/llm/openai')
      expect(host).to have_received(:load_optional_feature).with('legion/extensions/llm/gemini')
      expect(host).to have_received(:load_optional_feature).with('legion/extensions/llm/mlx')
      expect(host).to have_received(:load_optional_feature).with('legion/extensions/llm/bedrock')
      expect(host).to have_received(:load_optional_feature).with('legion/extensions/llm/azure_foundry')
      expect(host).to have_received(:load_optional_feature).with('legion/extensions/llm/vertex')
    end
  end

  describe '#lex_llm_provider_config_value' do
    it 'normalizes OpenAI-compatible /v1 base URLs for lex-llm providers' do
      value = host.send(
        :lex_llm_provider_config_value,
        :vllm,
        :vllm_api_base,
        { base_url: 'http://gpu:8000/v1' }
      )

      expect(value).to eq('http://gpu:8000')
    end

    it 'preserves versioned non-OpenAI-compatible provider base URLs' do
      value = host.send(
        :lex_llm_provider_config_value,
        :gemini,
        :gemini_api_base,
        { base_url: 'https://generativelanguage.googleapis.com/v1beta' }
      )

      expect(value).to eq('https://generativelanguage.googleapis.com/v1beta')
    end
  end

  describe '#resolve_credential_value' do
    before do
      hide_const('Legion::Identity::Broker')
      allow(Legion::LLM::Call::CodexConfigLoader).to receive(:read_token).and_return(nil)
    end

    around do |example|
      old_a = ENV.fetch('LEGION_TEST_A', nil)
      old_b = ENV.fetch('LEGION_TEST_B', nil)
      old_openai = ENV.fetch('OPENAI_API_KEY', nil)
      old_codex = ENV.fetch('CODEX_API_KEY', nil)
      ENV.delete('LEGION_TEST_A')
      ENV.delete('LEGION_TEST_B')
      ENV.delete('OPENAI_API_KEY')
      ENV.delete('CODEX_API_KEY')
      example.run
    ensure
      old_a.nil? ? ENV.delete('LEGION_TEST_A') : ENV['LEGION_TEST_A'] = old_a
      old_b.nil? ? ENV.delete('LEGION_TEST_B') : ENV['LEGION_TEST_B'] = old_b
      old_openai.nil? ? ENV.delete('OPENAI_API_KEY') : ENV['OPENAI_API_KEY'] = old_openai
      old_codex.nil? ? ENV.delete('CODEX_API_KEY') : ENV['CODEX_API_KEY'] = old_codex
    end

    it 'resolves env placeholders' do
      ENV['LEGION_TEST_A'] = 'resolved-key'

      expect(host.send(:resolve_credential_value, 'env://LEGION_TEST_A')).to eq('resolved-key')
    end

    it 'returns the first resolved value from placeholder arrays' do
      ENV['LEGION_TEST_B'] = 'second-key'

      expect(host.send(:resolve_credential_value, ['env://LEGION_TEST_A', 'env://LEGION_TEST_B'])).to eq('second-key')
    end

    it 'does not treat unresolved placeholder arrays as credentials' do
      expect(host.send(:credential_available_for?, :openai, { api_key: ['env://LEGION_TEST_A', 'env://LEGION_TEST_B'] })).to be false
    end
  end

  describe '#configure providers with env placeholders' do
    let(:ruby_llm_config) { double('config') }

    before do
      hide_const('Legion::Identity::Broker')
      allow(RubyLLM).to receive(:configure).and_yield(ruby_llm_config)
      allow(ruby_llm_config).to receive(:gemini_api_key=)
      allow(ruby_llm_config).to receive(:azure_api_base=)
      allow(ruby_llm_config).to receive(:azure_api_key=)
      allow(ruby_llm_config).to receive(:azure_ai_auth_token=)
      allow(ruby_llm_config).to receive(:vllm_api_base=)
      allow(ruby_llm_config).to receive(:vllm_api_key=)
    end

    around do |example|
      old_gemini = ENV.fetch('LEGION_TEST_GEMINI', nil)
      old_azure = ENV.fetch('LEGION_TEST_AZURE', nil)
      old_vllm = ENV.fetch('LEGION_TEST_VLLM', nil)
      ENV['LEGION_TEST_GEMINI'] = 'gemini-key'
      ENV['LEGION_TEST_AZURE'] = 'azure-key'
      ENV['LEGION_TEST_VLLM'] = 'vllm-key'
      example.run
    ensure
      old_gemini.nil? ? ENV.delete('LEGION_TEST_GEMINI') : ENV['LEGION_TEST_GEMINI'] = old_gemini
      old_azure.nil? ? ENV.delete('LEGION_TEST_AZURE') : ENV['LEGION_TEST_AZURE'] = old_azure
      old_vllm.nil? ? ENV.delete('LEGION_TEST_VLLM') : ENV['LEGION_TEST_VLLM'] = old_vllm
    end

    it 'resolves gemini env placeholders before configuring RubyLLM' do
      host.send(:configure_gemini, { api_key: 'env://LEGION_TEST_GEMINI' })

      expect(ruby_llm_config).to have_received(:gemini_api_key=).with('gemini-key')
    end

    it 'resolves azure env placeholders before configuring RubyLLM' do
      host.send(:configure_azure, { api_base: 'https://azure.example.com', api_key: 'env://LEGION_TEST_AZURE' })

      expect(ruby_llm_config).to have_received(:azure_api_key=).with('azure-key')
    end

    it 'resolves vllm env placeholders before configuring RubyLLM' do
      host.send(:configure_vllm, { base_url: 'http://gpu:8000/v1', api_key: 'env://LEGION_TEST_VLLM' })

      expect(ruby_llm_config).to have_received(:vllm_api_key=).with('vllm-key')
    end
  end

  describe '#broker_has_credential?' do
    context 'when Broker has an API key provider' do
      before do
        broker = Module.new do
          def self.token_for(name, **_kwargs)
            name == :openai ? 'sk-key' : nil
          end

          def self.renewer_for(_name) = nil
        end
        stub_const('Legion::Identity::Broker', broker)
      end

      it 'returns true for registered provider' do
        expect(host.send(:broker_has_credential?, :openai)).to be true
      end

      it 'returns false for unregistered provider' do
        expect(host.send(:broker_has_credential?, :gemini)).to be false
      end

      it 'includes audit purpose and context when probing Broker availability' do
        broker = Legion::Identity::Broker
        allow(broker).to receive(:token_for).and_call_original

        host.send(:broker_has_credential?, :openai)

        expect(broker).to have_received(:token_for).with(
          :openai,
          purpose: 'llm.provider.credential_available',
          context: { provider: :openai }
        )
      end
    end

    context 'when Broker has AWS credentials for bedrock' do
      before do
        creds = double('credentials', access_key_id: 'AKIA...')
        provider = double('provider', current_credentials: creds)
        renewer = double('renewer', provider: provider)
        broker = Module.new
        broker.define_singleton_method(:token_for) { |_, **_kwargs| nil }
        broker.define_singleton_method(:renewer_for) { |name| name == :aws ? renewer : nil }
        stub_const('Legion::Identity::Broker', broker)
      end

      it 'returns true for bedrock' do
        expect(host.send(:broker_has_credential?, :bedrock)).to be true
      end
    end

    context 'when Broker is not defined' do
      before { hide_const('Legion::Identity::Broker') }

      it 'returns false' do
        expect(host.send(:broker_has_credential?, :openai)).to be false
      end
    end
  end
end
