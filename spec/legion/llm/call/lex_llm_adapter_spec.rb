# frozen_string_literal: true

require 'spec_helper'

begin
  require 'legion/extensions/llm'
  require 'legion/extensions/llm/provider' unless defined?(::Legion::Extensions::Llm::Provider)
rescue LoadError
  nil
end

# Shared by the fake provider's complete/embed overrides (defined via
# define_method, so RSpec example-group helpers are not in scope there).
module LexLLMAdapterSpecHelpers
  def canonical_response(model:, text: 'hello', tool_calls: nil, usage: nil, stop_reason: :end_turn, thinking: nil)
    ::Legion::Extensions::Llm::Canonical::Response.build(
      text:        text,
      tool_calls:  tool_calls,
      usage:       usage || ::Legion::Extensions::Llm::Canonical::Usage.build(input_tokens: 7, output_tokens: 3),
      stop_reason: stop_reason,
      model:       model,
      thinking:    thinking
    )
  end
end

RSpec.describe Legion::LLM::Call::LexLLMAdapter do
  # Spec-local alias for every example; a top-level constant would pollute the
  # shared suite process, so the in-block definition is intentional.
  # rubocop:disable Lint/ConstantDefinitionInBlock
  Canonical = Legion::Extensions::Llm::Canonical
  # rubocop:enable Lint/ConstantDefinitionInBlock

  def lex_llm_test_namespace
    return ::Legion::Extensions::Llm if defined?(::Legion::Extensions::Llm::Provider)

    raise NameError, 'lex-llm provider namespace is not loaded'
  end

  def canonical_response(**)
    LexLLMAdapterSpecHelpers.new.canonical_response(**)
  end

  let(:provider_class) do
    namespace = lex_llm_test_namespace
    Class.new(namespace::Provider) do
      include LexLLMAdapterSpecHelpers

      define_method(:llm_namespace) { namespace }

      def api_base = 'https://adapter.invalid'

      def complete(_messages, model:, **)
        canonical_response(model: model)
      end

      def embed(text:, model:, dimensions:, params: {}, headers: {})
        self.class.last_embed_call = { text: text, model: model, dimensions: dimensions, params: params, headers: headers }
        {
          text:      text,
          model:     model,
          embedding: Array.new(dimensions || 2, 0.5),
          usage:     ::Legion::Extensions::Llm::Canonical::Usage.build(input_tokens: 4)
        }
      end

      def image(prompt:, model:, size:, with: nil, mask: nil, params: {}, headers: {})
        {
          model:   model,
          image:   'https://images.invalid/result.png',
          size:    size,
          with:    with,
          mask:    mask,
          headers: headers,
          params:  params,
          prompt:  prompt
        }
      end

      def health(live:)
        { status: live ? 'healthy' : 'unknown', ready: live }
      end

      def connection
        self.class.connection || super
      end

      class << self
        attr_accessor :connection, :last_embed_call
      end
    end
  end

  let(:adapter) { described_class.new(:fake_llm, provider_class) }
  let(:responses_adapter) { described_class.new(:fake_llm, provider_class, instance_config: { capabilities: [:responses] }) }

  it 'maps chat dispatch to lex-llm provider completion' do
    result = adapter.chat(model: 'model-a', messages: [{ role: 'user', content: 'hi' }])

    expect(result).to be_a(Canonical::Response)
    expect(result.text).to eq('hello')
    expect(result.usage.input_tokens).to eq(7)
    expect(result.usage.output_tokens).to eq(3)
  end

  it 'merges offering metadata into the response metadata when present' do
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

    expect(result.metadata[:offering]).to include(
      offering_id:           'azure:default:inference:gpt-4o',
      model_family:          :openai,
      canonical_model_alias: 'gpt-4o'
    )
  end

  it 'prepends system instructions to native chat messages' do
    provider_class.define_singleton_method(:last_messages) { @last_messages }
    provider_class.define_singleton_method(:last_messages=) { |messages| @last_messages = messages }
    provider_class.define_method(:complete) do |messages, model:, **|
      self.class.last_messages = messages
      canonical_response(model: model)
    end

    adapter.chat(model: 'model-a', messages: [{ role: 'user', content: 'hi' }], system: 'keep it short')

    expect(provider_class.last_messages).to all(be_a(Canonical::Message))
    expect(provider_class.last_messages.map(&:role)).to eq(%i[system user])
    expect(provider_class.last_messages.first.content).to eq('keep it short')
  end

  it 'maps embedding dispatch to the documented lex-llm embed artifact' do
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
    expect(provider_class.last_embed_call[:model]).to eq('embed-a')
  end

  it 'maps image dispatch to the documented lex-llm image artifact' do
    result = adapter.image(
      model:   'image-a',
      prompt:  'draw a clean interface',
      size:    '1024x1024',
      with:    'input.png',
      mask:    'mask.png',
      params:  { quality: 'high' },
      headers: { 'X-Test' => '1' }
    )

    expect(result[:image]).to eq('https://images.invalid/result.png')
    expect(result[:model]).to eq('image-a')
  end

  it 'maps health checks to the lex-llm provider health contract' do
    expect(adapter.health(live: true)).to eq(status: 'healthy', ready: true)
  end

  it 'streams canonical provider chunks through the callback and returns the final response' do
    provider_class.define_method(:complete) do |_messages, model:, **, &block|
      block.call(Canonical::Chunk.text_delta(delta: 'hel', request_id: 'req-1'))
      block.call(Canonical::Chunk.text_delta(delta: 'lo', request_id: 'req-1'))
      canonical_response(model: model, text: 'hello')
    end

    yielded = []
    result = adapter.stream(model: 'model-a', messages: [{ role: 'user', content: 'hi' }]) do |chunk|
      yielded << chunk.delta
    end

    expect(yielded).to eq(%w[hel lo])
    expect(result).to be_a(Canonical::Response)
    expect(result.text).to eq('hello')
    expect(result.model).to eq('model-a')
    expect(result.usage.input_tokens).to eq(7)
    expect(result.usage.output_tokens).to eq(3)
  end

  it 'calls upstream Responses API for non-streaming responses' do
    connection = Class.new do
      attr_reader :url, :payload

      def post(url, payload)
        @url = url
        @payload = payload
        response_body = {
          'model'  => 'gpt-5.4',
          'output' => [
            { 'content' => [{ 'type' => 'output_text', 'text' => 'hi' }] }
          ],
          'usage'  => { 'input_tokens' => 8, 'output_tokens' => 5 }
        }
        Struct.new(:body).new(response_body)
      end
    end.new
    provider_class.connection = connection

    result = responses_adapter.responses(
      model:    'gpt-5.4',
      body:     { input: 'say hi', stream: false },
      messages: [{ role: 'user', content: 'say hi' }]
    )

    expect(connection.url).to eq('/v1/responses')
    expect(connection.payload).to include(model: 'gpt-5.4', stream: false)
    expect(connection.payload[:input]).to eq('say hi')
    expect(result[:result]).to eq('hi')
    expect(result[:usage]).to include(input_tokens: 8, output_tokens: 5)
  ensure
    provider_class.connection = nil
  end

  it 'renders assistant tool_calls as function_call items paired with their outputs (Responses tool loop)' do
    connection = Class.new do
      attr_reader :payload

      def post(_url, payload)
        @payload = payload
        Struct.new(:body).new({
                                'model'  => 'gpt-5.4',
                                'output' => [{ 'content' => [{ 'type' => 'output_text', 'text' => 'done' }] }],
                                'usage'  => { 'input_tokens' => 8, 'output_tokens' => 5 }
                              })
      end
    end.new
    provider_class.connection = connection

    # Mirrors the native responses tool loop: body carries no :input, so the
    # adapter rebuilds the Responses input from the message history, which
    # includes the assistant turn that issued the tool call plus the tool result.
    responses_adapter.responses(
      model:    'gpt-5.4',
      body:     { stream: false },
      messages: [
        { role: 'user', content: 'list tools' },
        { role: 'assistant', content: '',
          tool_calls: [{ id: 'call_x', name: 'legion_list_all_tools', arguments: { value: 'ping' } }] },
        { role: 'tool', tool_call_id: 'call_x', name: 'legion_list_all_tools', content: 'echo:ping' }
      ]
    )

    input = connection.payload[:input]
    function_call = input.find { |item| item[:type] == 'function_call' && item[:call_id] == 'call_x' }
    function_output = input.find { |item| item[:type] == 'function_call_output' && item[:call_id] == 'call_x' }

    # Without the function_call item, OpenAI rejects the function_call_output with
    # "No tool call found for function call output with call_id call_x".
    expect(function_call).not_to(be_nil, -> { "missing function_call item; input=#{input.inspect}" })
    expect(function_call[:name]).to eq('legion_list_all_tools')
    expect(function_call[:arguments]).to be_a(String) # OpenAI requires a JSON string
    expect(function_output).not_to be_nil
    expect(input.index(function_call)).to be < input.index(function_output)
  ensure
    provider_class.connection = nil
  end

  it 'preserves Responses input_text content parts when building upstream payloads' do
    connection = Class.new do
      attr_reader :payload

      def post(_url, payload)
        @payload = payload
        Struct.new(:body).new({
                                'model'  => 'gpt-5.4',
                                'output' => [{ 'content' => [{ 'type' => 'output_text', 'text' => 'hi' }] }],
                                'usage'  => { 'input_tokens' => 8, 'output_tokens' => 5 }
                              })
      end
    end.new
    provider_class.connection = connection

    responses_adapter.responses(
      model:    'gpt-5.4',
      body:     { stream: false },
      messages: [{ role: 'user', content: [{ type: 'input_text', text: 'say hi' }] }]
    )

    expect(connection.payload[:input]).to eq(
      [{ role: 'user', content: [{ type: 'input_text', text: 'say hi' }] }]
    )
  ensure
    provider_class.connection = nil
  end

  it 'rejects Responses API dispatch for providers without responses capability' do
    expect do
      adapter.responses(model: 'model-a', body: { input: 'hi' }, messages: [{ role: 'user', content: 'hi' }])
    end.to raise_error(Legion::LLM::ProviderError, /Responses API dispatch is not supported/)
  end

  describe '#supports?' do
    it 'returns false for :responses on a provider not in the family list and no explicit capability' do
      non_responses = described_class.new(:vllm, provider_class)
      expect(non_responses.supports?(:responses)).to be false
    end

    it 'returns false for :responses on an arbitrary provider name not in the family list' do
      non_responses = described_class.new(:ollama, provider_class)
      expect(non_responses.supports?(:responses)).to be false
    end

    it 'returns true for :responses on the openai provider family' do
      openai_adapter = described_class.new(:openai, provider_class)
      expect(openai_adapter.supports?(:responses)).to be true
    end

    it 'returns true for :responses when instance_config explicitly declares it' do
      explicit = described_class.new(:vllm, provider_class, instance_config: { capabilities: [:responses] })
      expect(explicit.supports?(:responses)).to be true
    end

    it 'returns true for non-responses capabilities on any provider' do
      expect(described_class.new(:vllm, provider_class).supports?(:chat)).to be true
      expect(described_class.new(:ollama, provider_class).supports?(:embed)).to be true
    end
  end

  it 'streams upstream Responses API deltas as canonical chunks and captures completed usage' do
    connection = Class.new do
      attr_reader :payload

      def post(_url, payload)
        @payload = payload
        options = Struct.new(:on_data, keyword_init: true).new
        request = Struct.new(:headers, :options, keyword_init: true).new(headers: {}, options: options)
        yield request
        request.options.on_data.call(sse('response.output_text.delta', type: 'response.output_text.delta', delta: 'hi'))
        request.options.on_data.call(sse('response.completed',
                                         type:     'response.completed',
                                         response: { model: 'gpt-5.4', usage: { input_tokens: 8, output_tokens: 5 } }))
        Struct.new(:body).new(nil)
      end

      def sse(event, payload)
        "event: #{event}\ndata: #{Legion::JSON.dump(payload)}\n\n"
      end
    end.new
    provider_class.connection = connection

    yielded = []
    result = responses_adapter.responses(
      model:    'gpt-5.4',
      body:     { input: 'say hi', stream: true },
      stream:   true,
      messages: [{ role: 'user', content: 'say hi' }]
    ) { |chunk| yielded << chunk }

    expect(connection.payload).to include(model: 'gpt-5.4', stream: true)
    expect(yielded).to all(be_a(Canonical::Chunk))
    expect(yielded.map(&:delta)).to eq(['hi'])
    expect(result[:result]).to eq('hi')
    expect(result[:model]).to eq('gpt-5.4')
    expect(result[:usage]).to include(input_tokens: 8, output_tokens: 5)
  ensure
    provider_class.connection = nil
  end

  it 'uses the final streamed provider response for accumulated tool calls' do
    provider_class.define_method(:complete) do |_messages, model:, **, &block|
      block.call(
        Canonical::Chunk.tool_call_delta(
          tool_call:  { id: 'call-1', name: 'legion_tool', arguments: '{"chat_id":"chat-123"}' },
          request_id: 'req-1'
        )
      )

      canonical_response(
        model:       model,
        text:        nil,
        stop_reason: :tool_use,
        tool_calls:  [
          Canonical::ToolCall.build(id: 'call-1', name: 'legion_tool', arguments: { 'chat_id' => 'chat-123' })
        ]
      )
    end

    result = adapter.stream(model: 'model-a', messages: [{ role: 'user', content: 'hi' }])

    expect(result.tool_calls.first.name).to eq('legion_tool')
    expect(result.tool_calls.first.arguments).to eq('chat_id' => 'chat-123')
    expect(result.stop_reason).to eq(:tool_use)
  end

  it 'builds fallback streamed responses from accumulated canonical chunk state' do
    provider_class.define_method(:complete) do |_messages, **, &block|
      block.call(Canonical::Chunk.text_delta(delta: 'run ', request_id: 'req-1'))
      block.call(
        Canonical::Chunk.tool_call_delta(
          tool_call:  { id: 'call-1', name: 'legion_tool', arguments: '{"chat_id":"chat-123"}' },
          request_id: 'req-1'
        )
      )
      nil
    end

    result = adapter.stream(model: 'model-a', messages: [{ role: 'user', content: 'hi' }])

    expect(result).to be_a(Canonical::Response)
    expect(result.text).to eq('run ')
    expect(result.model).to eq('model-a')
    expect(result.tool_calls.first.name).to eq('legion_tool')
    # JSON-string arguments are parsed at the edge (03 O03a); Legion::JSON
    # returns symbol keys.
    expect(result.tool_calls.first.arguments).to eq(chat_id: 'chat-123')
    expect(result.stop_reason).to eq(:tool_use)
  end

  it 'does not retain stream chunk objects in fallback state' do
    chunk = Canonical::Chunk.text_delta(delta: 'hello', request_id: 'req-1')
    accumulator = adapter.send(:build_stream_accumulator)

    adapter.send(:accumulate_stream_chunk, accumulator, chunk)

    expect(accumulator).not_to have_key(:chunks)
    expect(accumulator.values).not_to include(chunk)
  end

  it 'accumulates canonical thinking deltas into the fallback response' do
    provider_class.define_method(:complete) do |_messages, **, &block|
      block.call(Canonical::Chunk.text_delta(delta: 'answer', request_id: 'req-1'))
      block.call(Canonical::Chunk.thinking_delta(delta: 'internal reasoning', request_id: 'req-1', signature: 'sig-1'))
      nil
    end

    result = adapter.stream(model: 'model-a', messages: [{ role: 'user', content: 'hi' }])

    expect(result.text).to eq('answer')
    expect(result.thinking.content).to eq('internal reasoning')
    expect(result.thinking.signature).to eq('sig-1')
  end

  it 'extracts token usage from a canonical usage object' do
    usage = Canonical::Usage.build(input_tokens: 8, output_tokens: 6, cache_read_tokens: 2, cache_write_tokens: 1)

    expect(adapter.send(:usage_hash, usage)).to eq(
      input_tokens:       8,
      output_tokens:      6,
      cache_read_tokens:  2,
      cache_write_tokens: 1
    )
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

  # Regression: lex-llm-* actors call adapter.discover_offerings (not adapter.offerings).
  # Without this method on the adapter, every actor's lanes_from_instance silently returns
  # [] → Inventory stays empty → all routing returns NoLaneAvailable.
  it 'forwards discover_offerings to the provider (lex-llm-* actor contract)' do
    provider_class.define_method(:discover_offerings) do |live: false, **|
      [{ offering_id: 'fake:default:inference:model-a', model: 'model-a', live: live }]
    end

    expect(adapter).to respond_to(:discover_offerings)
    expect(adapter.discover_offerings(live: true)).to eq([
                                                           { offering_id: 'fake:default:inference:model-a',
                                                             model: 'model-a', live: true }
                                                         ])
  end

  context 'Anthropic-style structured content blocks in messages (#123)' do
    it 'flattens symbol-keyed text blocks to a plain string' do
      messages_seen = nil
      provider_class.define_method(:complete) do |messages, model:, **|
        messages_seen = messages
        canonical_response(model: model)
      end

      adapter.chat(
        model:    'model-a',
        messages: [{ role: 'user', content: [{ type: 'text', text: 'tell me a dad joke' }] }]
      )

      expect(messages_seen).to all(be_a(Canonical::Message))
      expect(messages_seen.first.content).to eq('tell me a dad joke')
    end

    it 'flattens string-keyed text blocks to a plain string' do
      messages_seen = nil
      provider_class.define_method(:complete) do |messages, model:, **|
        messages_seen = messages
        canonical_response(model: model)
      end

      adapter.chat(
        model:    'model-a',
        messages: [{ role: 'user', content: [{ 'type' => 'text', 'text' => 'tell me a dad joke' }] }]
      )

      expect(messages_seen.first.content).to eq('tell me a dad joke')
    end

    it 'joins multiple text blocks' do
      messages_seen = nil
      provider_class.define_method(:complete) do |messages, model:, **|
        messages_seen = messages
        canonical_response(model: model)
      end

      adapter.chat(
        model:    'model-a',
        messages: [{ role: 'user', content: [{ type: 'text', text: 'part one' }, { type: 'text', text: 'part two' }] }]
      )

      expect(messages_seen.first.content).to eq("part one\n\npart two")
    end

    it 'skips non-text blocks (tool_use) and returns remaining text' do
      messages_seen = nil
      provider_class.define_method(:complete) do |messages, model:, **|
        messages_seen = messages
        canonical_response(model: model)
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

  it 'normalize_message_tool_calls returns Array of Canonical::ToolCall objects, not a Hash' do
    tool_calls_input = [
      { id: 'call-1', name: 'legion_list_all_tools', arguments: {} },
      { id: 'call-2', name: 'ruby', arguments: { code: 'puts 1' } }
    ]

    result = adapter.send(:normalize_message_tool_calls, tool_calls_input)

    expect(result).to be_an(Array)
    expect(result.size).to eq(2)
    expect(result.first).to be_a(Canonical::ToolCall)
    expect(result.first.name).to eq('legion_list_all_tools')
    expect(result.first.id).to eq('call-1')
    expect(result.last.name).to eq('ruby')
    expect(result.last.arguments).to eq(code: 'puts 1')
  end

  it 'normalizes JSON-string tool arguments to a Hash at the edge (03 O03a)' do
    result = adapter.send(:normalize_message_tool_calls,
                          [{ id: 'call-1', name: 'lookup', arguments: '{"query":"status"}' }])

    expect(result.first.arguments).to eq(query: 'status')
  end

  # Reproduction for ContentBlock#inspect leak (2026-06-25):
  # When ContentBlock objects flow through normalize_message_content (replayed
  # history from canonical messages), the block branch must extract .text, not
  # return nil and fall through to Array#to_s which dumps the raw #inspect.
  it 'extracts text from ContentBlock objects in message content' do
    canonical_ns = ::Legion::Extensions::Llm::Canonical
    content_blocks = [
      canonical_ns::ContentBlock.from_hash(type: 'text', text: "The seat templates don't apply here.")
    ]

    provider_class.define_method(:complete) do |messages, model:, **|
      assistant_msg = messages.find { |m| m.role == :assistant }
      content_text = assistant_msg&.content
      canonical_response(model: model, text: "got: #{content_text}")
    end

    messages = [
      { role: 'user', content: 'What templates exist?' },
      { role: 'assistant', content: content_blocks },
      { role: 'user', content: 'OK thanks' }
    ]

    result = adapter.chat(model: 'model-a', messages: messages)

    expect(result.text).not_to include('#<data')
    expect(result.text).not_to include('ContentBlock')
    expect(result.text).to include("The seat templates don't apply here.")
  end
end
