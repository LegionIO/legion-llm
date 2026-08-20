# frozen_string_literal: true

require 'spec_helper'

RSpec.describe Legion::LLM::Call::Dispatch do
  before { Legion::LLM::Call::Registry.reset! }

  let(:fake_ext) do
    Module.new do
      module_function

      def chat(**)
        { content: 'hello from native', usage: { input_tokens: 10, output_tokens: 5 } }
      end

      def embed(**)
        { content: [0.1, 0.2], usage: { input_tokens: 3, output_tokens: 0 } }
      end

      def stream(**, &)
        { content: 'streamed', usage: { input_tokens: 8, output_tokens: 4 } }
      end

      def count_tokens(**)
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
        expect(result[:usage]).to be_a(Legion::Extensions::Llm::Canonical::Usage)
        expect(result[:usage].input_tokens).to eq(10)
        expect(result[:usage].output_tokens).to eq(5)
      end

      it 'passes offering metadata through registered native providers' do
        seen = nil
        ext = Module.new do
          define_singleton_method(:chat) do |model:, messages:, **opts|
            seen = { model: model, messages: messages, opts: opts }
            { content: 'ok', usage: {}, metadata: { offering: opts[:offering_metadata] } }
          end
        end
        Legion::LLM::Call::Registry.register(:offering_provider, ext)

        result = described_class.dispatch_chat(
          provider:          :offering_provider,
          model:             'deployment-a',
          messages:          [{ role: 'user', content: 'hi' }],
          offering_id:       'azure:default:inference:gpt-4o',
          offering_metadata: { offering_id: 'azure:default:inference:gpt-4o', provider_instance: :eastus }
        )

        expect(seen[:opts]).to include(
          offering_id:       'azure:default:inference:gpt-4o',
          offering_metadata: { offering_id: 'azure:default:inference:gpt-4o', provider_instance: :eastus }
        )
        expect(result[:metadata]).to include(
          offering: { offering_id: 'azure:default:inference:gpt-4o', provider_instance: :eastus }
        )
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
      expect(result[:usage]).to be_a(Legion::Extensions::Llm::Canonical::Usage)
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
      expect(result[:usage]).to be_a(Legion::Extensions::Llm::Canonical::Usage)
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
      expect(result[:usage]).to be_a(Legion::Extensions::Llm::Canonical::Usage)
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

    it 'normalizes empty string tool-call arguments to an empty hash' do
      Legion::LLM::Call::Registry.register(:openai, Module.new do
        define_singleton_method(:chat) do |**|
          {
            content:    '',
            usage:      {},
            tool_calls: [{ id: 'call_1', function: { name: 'mcp_servers', arguments: '' } }]
          }
        end
      end)

      result = described_class.dispatch_chat(provider: :openai, model: nil, messages: [])

      expect(result[:tool_calls].first[:arguments]).to eq({})
    end
  end
end

# P4a: NativeResponseAdapter was deleted; Dispatch now returns Canonical::Response.
# These specs verify the canonical adapter provides backward-compatible hash-key access.
RSpec.describe Legion::LLM::Call::Dispatch, '.normalize_response (canonical)' do
  let(:canonical) { Legion::Extensions::Llm::Canonical }

  # Test the hash-key adapter on Canonical::Response
  it 'allows [:text] access on Canonical::Response' do
    response = canonical::Response.new(
      text: 'hello', thinking: nil, tool_calls: [],
      usage: canonical::Usage.new(input_tokens: 1, output_tokens: 2, cache_read_tokens: 0, cache_write_tokens: 0, thinking_tokens: 0, units: {}, metadata: {}),
      stop_reason: :end_turn, model: 'test', routing: {}, metadata: {}
    )
    expect(response[:text]).to eq('hello')
    expect(response[:content]).to eq('hello')   # backward-compatible alias
    expect(response[:result]).to eq('hello')    # backward-compatible alias
  end

  it 'allows hash-key access on Canonical::ToolCall' do
    tc = canonical::ToolCall.new(
      id: 'tc1', exchange_id: nil, name: 'write_file', arguments: { path: '/tmp/x' },
      source: { type: :registry }, status: :success, duration_ms: 50, result: 'ok',
      error: nil, started_at: nil, finished_at: nil, category: nil,
      data_handling_classification: nil, policy_decision: nil, metadata: {}
    )
    expect(tc[:id]).to eq('tc1')
    expect(tc[:name]).to eq('write_file')
    expect(tc[:arguments]).to eq({ path: '/tmp/x' })
  end

  it 'allows dig on Canonical::Response' do
    response = canonical::Response.new(
      text: 'hello', thinking: nil, tool_calls: [],
      usage: canonical::Usage.new(input_tokens: 1, output_tokens: 2, cache_read_tokens: 0, cache_write_tokens: 0, thinking_tokens: 0, units: {}, metadata: {}),
      stop_reason: :end_turn, model: 'test', routing: {}, metadata: { deep: { nested: 'value' } }
    )
    expect(response[:metadata][:deep][:nested]).to eq('value')
  end

  describe 'model policy enforcement (fail-closed, terminal)' do
    let(:guarded_ext) do
      Module.new do
        module_function

        def model_allowed?(model) = model.to_s.include?('haiku')
        def chat(**) = { content: 'should not reach', usage: {} }
      end
    end

    before { Legion::LLM::Call::Registry.register(:anthropic, guarded_ext) }

    it 'raises Legion::LLM::ModelNotAllowed and never invokes the provider for a denied model' do
      expect(guarded_ext).not_to receive(:chat)
      expect do
        described_class.call(provider: :anthropic, capability: :chat, model: 'claude-sonnet-4-6', messages: [])
      end.to raise_error(Legion::LLM::ModelNotAllowed, /not permitted/)
    end

    it 'is not retryable (terminal policy outcome)' do
      described_class.call(provider: :anthropic, capability: :chat, model: 'claude-sonnet-4-6', messages: [])
    rescue Legion::LLM::ModelNotAllowed => e
      expect(e).not_to be_retryable
    end

    it 'dispatches normally for an allowed model' do
      expect do
        described_class.call(provider: :anthropic, capability: :chat, model: 'claude-haiku-4-5', messages: [])
      end.not_to raise_error
    end

    it 'maps a provider-raised lex ModelNotAllowedError to Legion::LLM::ModelNotAllowed' do
      raising_ext = Module.new do
        module_function

        def chat(model:, **)
          raise Legion::Extensions::Llm::ModelNotAllowedError.new(model: model, provider: :anthropic)
        end
      end
      Legion::LLM::Call::Registry.register(:anthropic_raises, raising_ext)

      expect do
        described_class.call(provider: :anthropic_raises, capability: :chat, model: 'gpt-5.5', messages: [])
      end.to raise_error(Legion::LLM::ModelNotAllowed)
    end
  end
end
