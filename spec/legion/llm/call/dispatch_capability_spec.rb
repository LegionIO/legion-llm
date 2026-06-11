# frozen_string_literal: true

require 'spec_helper'

RSpec.describe Legion::LLM::Call::Dispatch, '.call' do
  before { Legion::LLM::Call::Registry.reset! }

  let(:mock_ext) do
    Module.new do
      module_function

      def chat(model:, messages:, **) # rubocop:disable Lint/UnusedMethodArgument
        { content: 'chat response', usage: { input_tokens: 10, output_tokens: 5 } }
      end

      def embed(model:, text:, **) # rubocop:disable Lint/UnusedMethodArgument
        { content: [0.1, 0.2], usage: { input_tokens: 3, output_tokens: 0 } }
      end

      def stream(model:, messages:, **, &) # rubocop:disable Lint/UnusedMethodArgument
        yield('chunk') if block_given?
        { content: 'streamed response', usage: { input_tokens: 8, output_tokens: 4 } }
      end

      def responses(model:, body:, messages:, stream:, **) # rubocop:disable Lint/UnusedMethodArgument
        { content: 'responses response', usage: { input_tokens: 11, output_tokens: 6 } }
      end

      def image(model:, prompt:, size:, **) # rubocop:disable Lint/UnusedMethodArgument
        { result: [{ url: 'https://images.invalid/generated.png' }], model: model, usage: {} }
      end
    end
  end

  describe 'capability routing' do
    before { Legion::LLM::Call::Registry.register(:ollama, mock_ext, instance: :local) }

    it 'dispatches chat capability — calls ext.chat' do
      result = described_class.call(
        provider: :ollama, capability: :chat, instance: :local,
        model: 'llama3', messages: [{ role: 'user', content: 'hi' }]
      )
      expect(result[:result]).to eq('chat response')
      expect(result[:usage]).to be_a(Legion::Extensions::Llm::Canonical::Usage)
      expect(result[:usage].input_tokens).to eq(10)
    end

    it 'dispatches embed capability — calls ext.embed' do
      result = described_class.call(
        provider: :ollama, capability: :embed, instance: :local,
        model: 'nomic-embed', text: 'hello world'
      )
      expect(result[:usage]).to be_a(Legion::Extensions::Llm::Canonical::Usage)
      expect(result[:usage].input_tokens).to eq(3)
    end

    it 'dispatches stream capability with block — calls ext.stream' do
      chunks = []
      result = described_class.call(
        provider: :ollama, capability: :stream, instance: :local,
        model: 'llama3', messages: [{ role: 'user', content: 'hi' }]
      ) { |chunk| chunks << chunk }

      expect(result[:result]).to eq('streamed response')
      expect(result[:usage].output_tokens).to eq(4)
      expect(chunks).to eq(['chunk'])
    end

    it 'dispatches responses capability — calls ext.responses' do
      result = described_class.call(
        provider: :ollama, capability: :responses, instance: :local,
        model: 'llama3', body: { input: 'hi' }, messages: [{ role: 'user', content: 'hi' }], stream: false
      )

      expect(result[:result]).to eq('responses response')
      expect(result[:usage].input_tokens).to eq(11)
    end

    it 'rejects responses capability when an adapter explicitly does not support it' do
      unsupported = Class.new do
        def supports?(capability) = capability.to_sym != :responses

        def responses(**)
          raise 'should not dispatch'
        end
      end.new
      Legion::LLM::Call::Registry.register(:unsupported, unsupported, instance: :local)

      expect do
        described_class.call(
          provider: :unsupported, capability: :responses, instance: :local,
          model: 'model-a', body: { input: 'hi' }, messages: [{ role: 'user', content: 'hi' }], stream: false
        )
      end.to raise_error(Legion::LLM::ProviderError, /unsupported capability responses/)
    end

    it 'dispatches image capability — calls ext.image' do
      result = described_class.call(
        provider: :ollama, capability: :image, instance: :local,
        model: 'image-model', prompt: 'draw an icon', size: '1024x1024'
      )

      expect(result[:result]).to eq([{ url: 'https://images.invalid/generated.png' }])
      expect(result[:model]).to eq('image-model')
    end

    it 'accepts string capability and coerces to symbol' do
      result = described_class.call(
        provider: :ollama, capability: 'chat', instance: :local,
        model: 'llama3', messages: [{ role: 'user', content: 'hi' }]
      )
      expect(result[:result]).to eq('chat response')
    end
  end

  describe 'instance resolution' do
    let(:default_ext) do
      Module.new do
        module_function

        def chat(model:, messages:, **) # rubocop:disable Lint/UnusedMethodArgument
          { content: 'default instance', usage: { input_tokens: 1, output_tokens: 1 } }
        end
      end
    end

    let(:named_ext) do
      Module.new do
        module_function

        def chat(model:, messages:, **) # rubocop:disable Lint/UnusedMethodArgument
          { content: 'named instance', usage: { input_tokens: 2, output_tokens: 2 } }
        end
      end
    end

    before do
      Legion::LLM::Call::Registry.register(:ollama, default_ext)
      Legion::LLM::Call::Registry.register(:ollama, named_ext, instance: :apollo)
    end

    it 'resolves named instance from Registry when specified' do
      result = described_class.call(
        provider: :ollama, capability: :chat, instance: :apollo,
        model: 'llama3', messages: []
      )
      expect(result[:result]).to eq('named instance')
    end

    it 'resolves default instance when instance is not specified' do
      result = described_class.call(
        provider: :ollama, capability: :chat,
        model: 'llama3', messages: []
      )
      expect(result[:result]).to eq('default instance')
    end

    it 'resolves default instance when instance is nil' do
      result = described_class.call(
        provider: :ollama, capability: :chat, instance: nil,
        model: 'llama3', messages: []
      )
      expect(result[:result]).to eq('default instance')
    end
  end

  describe 'error handling' do
    it 'raises ProviderError for unregistered provider' do
      expect do
        described_class.call(provider: :nonexistent, capability: :chat, model: 'x', messages: [])
      end.to raise_error(Legion::LLM::ProviderError, /not registered/)
    end

    it 'includes instance in error message when specified' do
      expect do
        described_class.call(provider: :ollama, capability: :chat, instance: :missing, model: 'x', messages: [])
      end.to raise_error(Legion::LLM::ProviderError, %r{ollama/missing})
    end

    it 'raises ProviderError for unsupported capability' do
      Legion::LLM::Call::Registry.register(:ollama, mock_ext, instance: :local)
      expect do
        described_class.call(provider: :ollama, capability: :invalid, instance: :local, model: 'x', messages: [])
      end.to raise_error(Legion::LLM::ProviderError, /unsupported capability: invalid/)
    end
  end

  describe 'deprecation delegates' do
    before do
      Legion::LLM::Call::Registry.register(:ollama, mock_ext, instance: :local)
      # Reset warn-once flags so each example starts clean
      %i[@chat_deprecation_warned @embed_deprecation_warned @stream_deprecation_warned
         @count_tokens_deprecation_warned].each do |ivar|
        described_class.instance_variable_set(ivar, nil)
      end
    end

    it 'dispatch_chat delegates to call with capability: :chat' do
      allow(described_class).to receive(:call).and_call_original
      described_class.dispatch_chat(provider: :ollama, model: 'llama3', messages: [{ role: 'user', content: 'hi' }])
      expect(described_class).to have_received(:call).with(hash_including(capability: :chat))
    end

    it 'dispatch_embed delegates to call with capability: :embed' do
      allow(described_class).to receive(:call).and_call_original
      described_class.dispatch_embed(provider: :ollama, model: 'nomic', text: 'hello')
      expect(described_class).to have_received(:call).with(hash_including(capability: :embed))
    end

    it 'dispatch_stream delegates to call with capability: :stream' do
      allow(described_class).to receive(:call).and_call_original
      described_class.dispatch_stream(provider: :ollama, model: 'llama3', messages: [{ role: 'user', content: 'hi' }])
      expect(described_class).to have_received(:call).with(hash_including(capability: :stream))
    end

    it 'dispatch_chat emits deprecation warning once' do
      allow(described_class.log).to receive(:warn)
      described_class.dispatch_chat(provider: :ollama, model: 'llama3', messages: [])
      described_class.dispatch_chat(provider: :ollama, model: 'llama3', messages: [])
      expect(described_class.log).to have_received(:warn).with(/DEPRECATED.*dispatch_chat/).once
    end

    it 'dispatch_embed emits deprecation warning once' do
      allow(described_class.log).to receive(:warn)
      described_class.dispatch_embed(provider: :ollama, model: 'nomic', text: 'hi')
      described_class.dispatch_embed(provider: :ollama, model: 'nomic', text: 'hi')
      expect(described_class.log).to have_received(:warn).with(/DEPRECATED.*dispatch_embed/).once
    end

    it 'dispatch_stream emits deprecation warning once' do
      allow(described_class.log).to receive(:warn)
      described_class.dispatch_stream(provider: :ollama, model: 'llama3', messages: [])
      described_class.dispatch_stream(provider: :ollama, model: 'llama3', messages: [])
      expect(described_class.log).to have_received(:warn).with(/DEPRECATED.*dispatch_stream/).once
    end
  end
end
