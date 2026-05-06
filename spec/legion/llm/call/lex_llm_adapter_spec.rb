# frozen_string_literal: true

require 'spec_helper'

begin
  require 'legion/extensions/llm'
  require 'legion/extensions/llm/provider' unless defined?(::Legion::Extensions::Llm::Provider)
rescue LoadError
  nil
end

RSpec.describe Legion::LLM::Call::LexLLMAdapter do
  def lex_llm_test_namespace
    return ::Legion::Extensions::Llm if defined?(::Legion::Extensions::Llm::Provider)

    raise NameError, 'lex-llm provider namespace is not loaded'
  end

  let(:provider_class) do
    namespace = lex_llm_test_namespace
    Class.new(namespace::Provider) do
      define_method(:llm_namespace) { namespace }

      def api_base = 'https://adapter.invalid'

      def complete(_messages, model:, **)
        llm_namespace::Message.new(role: :assistant, content: "hello #{model.id}", model_id: model.id,
                                   input_tokens: 7, output_tokens: 3)
      end

      def embed(text:, model:, dimensions:, params: {}, headers: {})
        self.class.last_embed_call = { text: text, model: model, dimensions: dimensions, params: params, headers: headers }
        llm_namespace::Embedding.new(vectors: Array.new(dimensions || 2, 0.5), model: model, input_tokens: 4)
      end

      def image(prompt:, model:, size:, with: nil, mask: nil, params: {}, headers: {})
        {
          result:  [{ url: 'https://images.invalid/result.png' }],
          model:   model,
          usage:   {},
          headers: headers,
          params:  params,
          prompt:  prompt,
          size:    size,
          with:    with,
          mask:    mask
        }
      end

      def health(live:)
        { status: live ? 'healthy' : 'unknown', ready: live }
      end

      class << self
        attr_accessor :last_embed_call
      end
    end
  end

  let(:adapter) { described_class.new(:fake_llm, provider_class) }

  it 'maps chat dispatch to lex-llm provider completion' do
    result = adapter.chat(model: 'model-a', messages: [{ role: 'user', content: 'hi' }])

    expect(result[:result]).to eq('hello model-a')
    expect(result[:usage]).to include(input_tokens: 7, output_tokens: 3)
  end

  it 'passes offering metadata through lex-llm model info when present' do
    provider_class.define_singleton_method(:last_model) { @last_model }
    provider_class.define_singleton_method(:last_model=) { |model| @last_model = model }
    provider_class.define_method(:complete) do |_messages, model:, **|
      self.class.last_model = model
      llm_namespace::Message.new(role: :assistant, content: "hello #{model.id}", model_id: model.id)
    end

    result = adapter.chat(
      model:             'deployment-a',
      messages:          [{ role: 'user', content: 'hi' }],
      offering_metadata: {
        offering_id:           'azure:default:inference:gpt-4o',
        model_family:          :openai,
        canonical_model_alias: 'gpt-4o',
        routing_metadata:      { deployment: 'deployment-a' }
      }
    )

    expect(provider_class.last_model.metadata).to include(
      offering_id:           'azure:default:inference:gpt-4o',
      model_family:          :openai,
      canonical_model_alias: 'gpt-4o'
    )
    expect(result[:metadata]).to include(offering: hash_including(offering_id: 'azure:default:inference:gpt-4o'))
  end

  it 'prepends system instructions to native chat messages' do
    provider_class.define_singleton_method(:last_messages) { @last_messages }
    provider_class.define_singleton_method(:last_messages=) { |messages| @last_messages = messages }
    provider_class.define_method(:complete) do |messages, model:, **|
      self.class.last_messages = messages
      llm_namespace::Message.new(role: :assistant, content: "hello #{model.id}", model_id: model.id)
    end

    adapter.chat(model: 'model-a', messages: [{ role: 'user', content: 'hi' }], system: 'keep it short')

    expect(provider_class.last_messages.map(&:role)).to eq(%i[system user])
    expect(provider_class.last_messages.first.content).to eq('keep it short')
  end

  it 'maps embedding dispatch to lex-llm provider embeddings' do
    result = adapter.embed(
      model:      'embed-a',
      text:       'hello',
      dimensions: 3,
      params:     { input_type: 'query' },
      headers:    { 'X-Test' => '1' }
    )

    expect(result[:result]).to eq([0.5, 0.5, 0.5])
    expect(result[:usage]).to include(input_tokens: 4, output_tokens: 0)
    expect(provider_class.last_embed_call).to include(
      text:       'hello',
      dimensions: 3,
      params:     { input_type: 'query' },
      headers:    { 'X-Test' => '1' }
    )
    expect(provider_class.last_embed_call[:model]).to be_a(lex_llm_test_namespace::Model::Info)
  end

  it 'maps image dispatch to lex-llm provider image generation' do
    result = adapter.image(
      model:   'image-a',
      prompt:  'draw a clean interface',
      size:    '1024x1024',
      with:    'input.png',
      mask:    'mask.png',
      params:  { quality: 'high' },
      headers: { 'X-Test' => '1' }
    )

    expect(result[:result]).to eq([{ url: 'https://images.invalid/result.png' }])
    expect(result[:model]).to be_a(lex_llm_test_namespace::Model::Info)
    expect(result[:metadata]).to eq({})
  end

  it 'maps health checks to the lex-llm provider health contract' do
    expect(adapter.health(live: true)).to eq(status: 'healthy', ready: true)
  end

  it 'streams provider chunks through the callback and response accumulator' do
    provider_class.define_method(:complete) do |_messages, model:, **, &block|
      block.call(llm_namespace::Chunk.new(role: :assistant, content: 'hel', model_id: model.id))
      block.call(llm_namespace::Chunk.new(role: :assistant, content: 'lo', model_id: model.id,
                                          input_tokens: 7, output_tokens: 3))
    end

    yielded = []
    result = adapter.stream(model: 'model-a', messages: [{ role: 'user', content: 'hi' }]) do |chunk|
      yielded << chunk.content
    end

    expect(yielded).to eq(%w[hel lo])
    expect(result[:result]).to eq('hello')
    expect(result[:model]).to eq('model-a')
    expect(result[:usage]).to include(input_tokens: 7, output_tokens: 3)
  end

  it 'estimates token count for non-hash message inputs' do
    result = adapter.count_tokens(model: 'model-a', messages: ['hello world'])

    expect(result[:result]).to eq(3)
    expect(result[:usage]).to eq({})
  end

  it 'memoizes the lex-llm provider instance' do
    instantiations = 0
    provider_class.define_singleton_method(:instantiations) { instantiations }
    provider_class.define_method(:initialize) do |config|
      instantiations += 1
      super(config)
    end

    adapter.chat(model: 'model-a', messages: [{ role: 'user', content: 'hi' }])
    adapter.embed(model: 'embed-a', text: 'hello', dimensions: 3)

    expect(provider_class.instantiations).to eq(1)
  end

  it 'exposes provider-discovered offerings when supported' do
    provider_class.define_method(:discover_offerings) do |live: false, **|
      [{ offering_id: 'fake:default:inference:model-a', model: 'model-a', live: live }]
    end

    expect(adapter.offerings(live: true)).to eq([
                                                  { offering_id: 'fake:default:inference:model-a',
                                                    model: 'model-a', live: true }
                                                ])
  end

  it 'raises provider failures for the caller to classify' do
    provider_class.define_method(:complete) do |_messages, **|
      raise 'provider failed'
    end

    expect do
      adapter.chat(model: 'model-a', messages: [{ role: 'user', content: 'hi' }])
    end.to raise_error(RuntimeError, 'provider failed')
  end

  it 'raises when the lex-llm namespace has not been loaded' do
    hide_const('Legion::Extensions::Llm')

    expect do
      described_class.new(:fake_llm, Class.new)
    end.to raise_error(NameError, /lex-llm provider namespace/)
  end
end
