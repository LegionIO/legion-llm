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
      llm_namespace::Message.new(role: :assistant, content: 'hello', model_id: model.id,
                                 input_tokens: 7, output_tokens: 3)
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

  it 'uses the final streamed provider message for accumulated tool calls' do
    provider_class.define_method(:complete) do |_messages, model:, **, &block|
      block.call(
        llm_namespace::Chunk.new(
          role:       :assistant,
          content:    nil,
          model_id:   model.id,
          tool_calls: {
            'legion_tool' => llm_namespace::ToolCall.new(
              id:        'call-1',
              name:      'legion_tool',
              arguments: ''
            )
          }
        )
      )

      llm_namespace::Message.new(
        role:          :assistant,
        content:       nil,
        model_id:      model.id,
        tool_calls:    {
          legion_tool: llm_namespace::ToolCall.new(
            id:        'call-1',
            name:      'legion_tool',
            arguments: { 'chat_id' => 'chat-123' }
          )
        },
        input_tokens:  7,
        output_tokens: 3
      )
    end

    result = adapter.stream(model: 'model-a', messages: [{ role: 'user', content: 'hi' }])

    expect(result[:tool_calls].fetch(:legion_tool).arguments).to eq('chat_id' => 'chat-123')
    expect(result[:stop_reason]).to eq(:tool_use)
  end

  it 'builds fallback streamed responses from accumulated chunk state' do
    provider_class.define_method(:complete) do |_messages, model:, **, &block|
      block.call(llm_namespace::Chunk.new(role: :assistant, content: 'run ', model_id: model.id,
                                          input_tokens: 7, output_tokens: 1))
      block.call(
        llm_namespace::Chunk.new(
          role:          :assistant,
          content:       'tool',
          model_id:      model.id,
          tool_calls:    {
            legion_tool: llm_namespace::ToolCall.new(
              id:        'call-1',
              name:      'legion_tool',
              arguments: { 'chat_id' => 'chat-123' }
            )
          },
          input_tokens:  7,
          output_tokens: 3
        )
      )
      nil
    end

    result = adapter.stream(model: 'model-a', messages: [{ role: 'user', content: 'hi' }])

    expect(result[:result]).to eq('run tool')
    expect(result[:model]).to eq('model-a')
    expect(result[:usage]).to include(input_tokens: 7, output_tokens: 3)
    expect(result[:tool_calls].fetch(:legion_tool).arguments).to eq('chat_id' => 'chat-123')
    expect(result[:stop_reason]).to eq(:tool_use)
  end

  it 'does not retain stream chunk objects in fallback state' do
    chunk = lex_llm_test_namespace::Chunk.new(role: :assistant, content: 'hello', model_id: 'model-a',
                                              input_tokens: 7, output_tokens: 3)
    accumulator = adapter.send(:build_stream_accumulator)

    adapter.send(:accumulate_stream_chunk, accumulator, chunk)

    expect(accumulator).not_to have_key(:chunks)
    expect(accumulator.values).not_to include(chunk)
  end

  it 'accumulates plain string streaming thinking chunks' do
    chunk_class = Struct.new(:content, :model_id, :input_tokens, :output_tokens,
                             :cached_tokens, :cache_creation_tokens, :thinking,
                             keyword_init: true)
    provider_class.define_method(:complete) do |_messages, model:, **, &block|
      block.call(chunk_class.new(content: 'answer', model_id: model.id, input_tokens: 7, output_tokens: 3,
                                 cached_tokens: 0, cache_creation_tokens: 0))
      block.call(chunk_class.new(content: '', model_id: model.id, input_tokens: 7, output_tokens: 3,
                                 cached_tokens: 0, cache_creation_tokens: 0, thinking: 'internal reasoning'))
    end

    result = adapter.stream(model: 'model-a', messages: [{ role: 'user', content: 'hi' }])

    expect(result[:result]).to eq('answer')
    expect(result[:thinking]).to eq(content: 'internal reasoning', enabled: true)
  end

  it 'extracts token usage from raw data when direct token readers are zero' do
    response_class = Struct.new(
      :input_tokens, :output_tokens, :cached_tokens, :cache_creation_tokens, :usage, :raw,
      keyword_init: true
    )
    response = response_class.new(
      input_tokens:         0,
      output_tokens:        5,
      cached_tokens:        0,
      cache_creation_tokens: 0,
      usage:                nil,
      raw:                  { data: { input_tokens: 9, output_tokens: 5 } }
    )

    expect(adapter.send(:usage_hash, response)).to eq(
      input_tokens:       9,
      output_tokens:      5,
      cache_read_tokens:  0,
      cache_write_tokens: 0
    )
  end

  it 'extracts token usage from gateway response usage hashes' do
    response_class = Struct.new(
      :input_tokens, :output_tokens, :cached_tokens, :cache_creation_tokens, :usage,
      keyword_init: true
    )
    response = response_class.new(
      input_tokens:         0,
      output_tokens:        0,
      cached_tokens:        0,
      cache_creation_tokens: 0,
      usage:                {
        input_tokens:           8,
        input_tokens_details:   { cached_tokens: 0 },
        output_tokens:          6,
        output_tokens_details:  { reasoning_tokens: 0 },
        total_tokens:           14
      }
    )

    expect(adapter.send(:usage_hash, response)).to eq(
      input_tokens:       8,
      output_tokens:      6,
      cache_read_tokens:  0,
      cache_write_tokens: 0
    )
  end

  it 'extracts token usage from prompt/completion token usage hashes' do
    response_class = Struct.new(
      :input_tokens, :output_tokens, :cached_tokens, :cache_creation_tokens, :usage,
      keyword_init: true
    )
    response = response_class.new(
      input_tokens:         0,
      output_tokens:        0,
      cached_tokens:        0,
      cache_creation_tokens: 0,
      usage:                { prompt_tokens: 11, completion_tokens: 4 }
    )

    expect(adapter.send(:usage_hash, response)).to eq(
      input_tokens:       11,
      output_tokens:      4,
      cache_read_tokens:  0,
      cache_write_tokens: 0
    )
  end

  it 'merges stream usage from raw fallback data even when chunks omit input_tokens readers' do
    chunk_class = Struct.new(:content, :model_id, :usage, :raw, keyword_init: true)
    accumulator = adapter.send(:build_stream_accumulator)
    chunk = chunk_class.new(
      content:  'hi',
      model_id: 'model-a',
      usage:    nil,
      raw:      { response: { usage: { input_tokens: 8, output_tokens: 2 } } }
    )

    adapter.send(:accumulate_stream_usage, accumulator, chunk)

    expect(accumulator[:usage]).to include(input_tokens: 8, output_tokens: 2)
    expect(accumulator[:model]).to eq('model-a')
    expect(accumulator[:raw]).to eq(response: { usage: { input_tokens: 8, output_tokens: 2 } })
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

  context 'Anthropic-style structured content blocks in messages (#123)' do
    it 'flattens symbol-keyed text blocks to a plain string' do
      messages_seen = nil
      provider_class.define_method(:complete) do |messages, **|
        messages_seen = messages
        llm_namespace::Message.new(role: :assistant, content: 'ok', input_tokens: 1, output_tokens: 1)
      end

      adapter.chat(
        model:    'model-a',
        messages: [{ role: 'user', content: [{ type: 'text', text: 'tell me a dad joke' }] }]
      )

      expect(messages_seen.first.content).to eq('tell me a dad joke')
    end

    it 'flattens string-keyed text blocks to a plain string' do
      messages_seen = nil
      provider_class.define_method(:complete) do |messages, **|
        messages_seen = messages
        llm_namespace::Message.new(role: :assistant, content: 'ok', input_tokens: 1, output_tokens: 1)
      end

      adapter.chat(
        model:    'model-a',
        messages: [{ role: 'user', content: [{ 'type' => 'text', 'text' => 'tell me a dad joke' }] }]
      )

      expect(messages_seen.first.content).to eq('tell me a dad joke')
    end

    it 'joins multiple text blocks' do
      messages_seen = nil
      provider_class.define_method(:complete) do |messages, **|
        messages_seen = messages
        llm_namespace::Message.new(role: :assistant, content: 'ok', input_tokens: 1, output_tokens: 1)
      end

      adapter.chat(
        model:    'model-a',
        messages: [{ role: 'user', content: [{ type: 'text', text: 'part one' }, { type: 'text', text: 'part two' }] }]
      )

      expect(messages_seen.first.content).to eq("part one\n\npart two")
    end

    it 'skips non-text blocks (tool_use) and returns remaining text' do
      messages_seen = nil
      provider_class.define_method(:complete) do |messages, **|
        messages_seen = messages
        llm_namespace::Message.new(role: :assistant, content: 'ok', input_tokens: 1, output_tokens: 1)
      end

      adapter.chat(
        model:    'model-a',
        messages: [{
          role:    'user',
          content: [
            { type: 'text', text: 'hello' },
            { type: 'tool_use', id: 'tu_1', name: 'search', input: {} }
          ]
        }]
      )

      expect(messages_seen.first.content).to eq('hello')
    end
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
