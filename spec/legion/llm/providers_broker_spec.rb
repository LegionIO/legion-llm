# frozen_string_literal: true

RSpec.describe Legion::LLM::Providers do
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
          def self.token_for(name)
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
          def self.token_for(_name)
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
          def self.token_for(name)
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
          def self.token_for(_name) = nil
        end
        stub_const('Legion::Identity::Broker', broker)
      end

      it 'falls back to config api_key' do
        host.send(:configure_openai, { api_key: 'sk-settings-key' })
        expect(ruby_llm_config).to have_received(:openai_api_key=).with('sk-settings-key')
      end
    end
  end

  describe '#broker_has_credential?' do
    context 'when Broker has an API key provider' do
      before do
        broker = Module.new do
          def self.token_for(name)
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
    end

    context 'when Broker has AWS credentials for bedrock' do
      before do
        creds = double('credentials', access_key_id: 'AKIA...')
        provider = double('provider', current_credentials: creds)
        renewer = double('renewer', provider: provider)
        broker = Module.new
        broker.define_singleton_method(:token_for) { |_| nil }
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
