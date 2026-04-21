# frozen_string_literal: true

require 'spec_helper'

RSpec.describe Legion::LLM::Call::Dispatch do
  before { Legion::LLM::Call::Registry.reset! }

  let(:fake_ext) do
    Module.new do
      module_function

      def chat(model:, messages:, **) # rubocop:disable Lint/UnusedMethodArgument
        { content: 'hello from native', usage: { input_tokens: 10, output_tokens: 5 } }
      end

      def embed(model:, text:, **) # rubocop:disable Lint/UnusedMethodArgument
        { content: [0.1, 0.2], usage: { input_tokens: 3, output_tokens: 0 } }
      end

      def stream(model:, messages:, **, &) # rubocop:disable Lint/UnusedMethodArgument
        { content: 'streamed', usage: { input_tokens: 8, output_tokens: 4 } }
      end

      def count_tokens(model:, messages:, **) # rubocop:disable Lint/UnusedMethodArgument
        { content: 42, usage: {} }
      end
    end
  end

  describe '.dispatch_chat' do
    context 'when provider is registered' do
      before { Legion::LLM::Call::Registry.register(:claude, fake_ext) }

      it 'returns a normalized hash with :result and :usage keys' do
        result = described_class.dispatch_chat(
          provider: :claude,
          model:    'claude-sonnet-4-6',
          messages: [{ role: 'user', content: 'hi' }]
        )
        expect(result).to have_key(:result)
        expect(result).to have_key(:usage)
      end

      it 'sets :result to the extension content' do
        result = described_class.dispatch_chat(
          provider: :claude,
          model:    'claude-sonnet-4-6',
          messages: [{ role: 'user', content: 'hi' }]
        )
        expect(result[:result]).to eq('hello from native')
      end

      it 'wraps usage in a Usage struct' do
        result = described_class.dispatch_chat(
          provider: :claude,
          model:    'claude-sonnet-4-6',
          messages: [{ role: 'user', content: 'hi' }]
        )
        expect(result[:usage]).to be_a(Legion::LLM::Usage)
        expect(result[:usage].input_tokens).to eq(10)
        expect(result[:usage].output_tokens).to eq(5)
      end

      it 'accepts string provider name' do
        result = described_class.dispatch_chat(
          provider: 'claude',
          model:    nil,
          messages: []
        )
        expect(result[:result]).to eq('hello from native')
      end
    end

    context 'when provider is not registered' do
      it 'raises ProviderError' do
        expect do
          described_class.dispatch_chat(
            provider: :unknown,
            model:    'some-model',
            messages: []
          )
        end.to raise_error(Legion::LLM::ProviderError, /Native provider not registered: unknown/)
      end
    end
  end

  describe '.dispatch_embed' do
    before { Legion::LLM::Call::Registry.register(:bedrock, fake_ext) }

    it 'returns normalized hash' do
      result = described_class.dispatch_embed(provider: :bedrock, model: 'titan', text: 'hello')
      expect(result[:usage]).to be_a(Legion::LLM::Usage)
      expect(result[:usage].input_tokens).to eq(3)
    end

    it 'raises ProviderError when not registered' do
      expect do
        described_class.dispatch_embed(provider: :missing, model: nil, text: '')
      end.to raise_error(Legion::LLM::ProviderError)
    end
  end

  describe '.dispatch_stream' do
    before { Legion::LLM::Call::Registry.register(:claude, fake_ext) }

    it 'returns normalized hash' do
      result = described_class.dispatch_stream(
        provider: :claude,
        model:    'claude-sonnet-4-6',
        messages: [{ role: 'user', content: 'hi' }]
      )
      expect(result[:result]).to eq('streamed')
      expect(result[:usage].output_tokens).to eq(4)
    end

    it 'raises ProviderError when not registered' do
      expect do
        described_class.dispatch_stream(provider: :missing, model: nil, messages: [])
      end.to raise_error(Legion::LLM::ProviderError)
    end
  end

  describe '.dispatch_count_tokens' do
    before { Legion::LLM::Call::Registry.register(:claude, fake_ext) }

    it 'returns normalized hash' do
      result = described_class.dispatch_count_tokens(
        provider: :claude,
        model:    'claude-sonnet-4-6',
        messages: []
      )
      expect(result[:result]).to eq(42)
      expect(result[:usage]).to be_a(Legion::LLM::Usage)
    end

    it 'raises ProviderError when not registered' do
      expect do
        described_class.dispatch_count_tokens(provider: :missing, model: nil, messages: [])
      end.to raise_error(Legion::LLM::ProviderError)
    end
  end

  describe '.available?' do
    it 'returns true when provider is registered' do
      Legion::LLM::Call::Registry.register(:bedrock, fake_ext)
      expect(described_class.available?(:bedrock)).to be true
    end

    it 'returns false when provider is not registered' do
      expect(described_class.available?(:ghost)).to be false
    end
  end

  describe 'normalize_response' do
    it 'wraps a non-Hash raw response' do
      Legion::LLM::Call::Registry.register(:openai, Module.new do
        module_function

        def chat(**)
          'plain string'
        end
      end)
      result = described_class.dispatch_chat(provider: :openai, model: nil, messages: [])
      expect(result[:result]).to eq('plain string')
      expect(result[:usage]).to be_a(Legion::LLM::Usage)
    end

    it 'passes through a Usage struct when already wrapped' do
      usage_struct = Legion::LLM::Usage.new(input_tokens: 99, output_tokens: 1)
      ext = Module.new do
        define_method(:chat) do |**|
          { result: 'done', usage: usage_struct }
        end
        module_function :chat
      end
      Legion::LLM::Call::Registry.register(:passthru, ext)
      result = described_class.dispatch_chat(provider: :passthru, model: nil, messages: [])
      expect(result[:usage].input_tokens).to eq(99)
    end
  end
end

RSpec.describe Legion::LLM::Call::NativeResponseAdapter do
  let(:usage_hash) { { input_tokens: 20, output_tokens: 10, cache_read_tokens: 5, cache_write_tokens: 2 } }
  let(:result_hash) { { result: 'some content', usage: Legion::LLM::Usage.new(**usage_hash) } }

  subject(:adapter) { described_class.new(result_hash) }

  it 'exposes #content' do
    expect(adapter.content).to eq('some content')
  end

  it 'exposes #input_tokens' do
    expect(adapter.input_tokens).to eq(20)
  end

  it 'exposes #output_tokens' do
    expect(adapter.output_tokens).to eq(10)
  end

  it 'exposes #cache_read_tokens' do
    expect(adapter.cache_read_tokens).to eq(5)
  end

  it 'exposes #cache_write_tokens' do
    expect(adapter.cache_write_tokens).to eq(2)
  end

  it 'exposes #usage as a Usage struct' do
    expect(adapter.usage).to be_a(Legion::LLM::Usage)
  end

  it 'converts nil result to empty string' do
    adapter = described_class.new({ result: nil, usage: Legion::LLM::Usage.new })
    expect(adapter.content).to eq('')
  end

  it 'uses zero values when usage is nil' do
    adapter = described_class.new({ result: 'hi', usage: nil })
    expect(adapter.input_tokens).to eq(0)
    expect(adapter.output_tokens).to eq(0)
  end
end
