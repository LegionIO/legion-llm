# frozen_string_literal: true

require 'spec_helper'
begin
  require 'sinatra/base'
  require 'legion/llm/api/native/inference'
rescue LoadError
  nil
end

# Verifies that the inference endpoint fix routes through the 18-step pipeline.
# Because rack-test is not a dependency, these specs exercise the pipeline
# integration path directly — confirming that calling Legion::LLM.chat with
# a messages: array (the pattern now used by the inference endpoint) goes
# through the pipeline when pipeline_enabled? is true.
RSpec.describe 'Inference endpoint pipeline routing' do
  let(:mock_session) do
    dbl = double('NativeChat')
    allow(dbl).to receive(:with_tool)
    allow(dbl).to receive(:with_instructions)
    allow(dbl).to receive(:add_message)
    dbl
  end

  let(:mock_response) do
    double('ProviderMessage',
           content:       'pipeline response',
           role:          'assistant',
           input_tokens:  8,
           output_tokens: 4,
           model_id:      'test-model')
  end

  before do
    Legion::Settings.merge_settings('llm', Legion::LLM::Settings.default)
    Legion::Settings[:llm][:default_model] = SSOT_TEST_MODEL
    allow(Legion::LLM).to receive(:started?).and_return(true)
    stub_native_provider(content: 'pipeline response')
    allow(mock_session).to receive(:ask).and_return(mock_response)
  end

  describe 'pipeline routing via messages: array' do
    it 'returns a Inference::Response when called with messages: array and pipeline enabled' do
      messages = [{ role: :user, content: 'what is legion?' }]
      result = Legion::LLM.chat(
        messages: messages,
        model:    SSOT_TEST_MODEL,
        caller:   { source: 'api', path: '/api/llm/inference' }
      )
      expect(result).to be_a(Legion::LLM::Inference::Response)
    end

    it 'carries the response content through the pipeline' do
      messages = [{ role: :user, content: 'hello' }]
      result = Legion::LLM.chat(messages: messages)
      expect(result.message[:content]).to eq('pipeline response')
    end

    it 'includes tracing in the pipeline response' do
      messages = [{ role: :user, content: 'trace me' }]
      result = Legion::LLM.chat(messages: messages)
      expect(result.tracing).to be_a(Hash)
      expect(result.tracing[:trace_id]).not_to be_nil
    end

    it 'includes a non-empty timeline in the pipeline response' do
      messages = [{ role: :user, content: 'timeline test' }]
      result = Legion::LLM.chat(messages: messages)
      expect(result.timeline).not_to be_empty
    end

    context 'with multi-turn messages' do
      let(:multi_turn_messages) do
        [
          { role: 'user',      content: 'what is ruby?' },
          { role: 'assistant', content: 'Ruby is a dynamic language.' },
          { role: 'user',      content: 'tell me more about ruby' }
        ]
      end

      it 'injects prior messages before the final ask' do
        # SSOT v3: dispatch goes through SelectionDispatch, not the legacy Call::Dispatch.
        # Verify all turns are forwarded to the callable (the executor must not drop prior context).
        captured_messages = nil
        allow(Legion::LLM::Call::SelectionDispatch).to receive(:call).and_wrap_original do |orig, **kw|
          captured_messages = kw[:arguments][:messages]
          orig.call(**kw)
        end

        Legion::LLM.chat(messages: multi_turn_messages)

        expect(captured_messages).to be_an(Array)
        expect(captured_messages.length).to be >= multi_turn_messages.length
      end

      it 'returns a Inference::Response for multi-turn conversations' do
        allow(mock_session).to receive(:add_message)
        result = Legion::LLM.chat(messages: multi_turn_messages)
        expect(result).to be_a(Legion::LLM::Inference::Response)
        expect(result.message[:content]).to eq('pipeline response')
      end
    end

    context 'with tool declarations' do
      let(:tool_class) do
        Class.new do
          define_singleton_method(:tool_name)   { 'test_tool' }
          define_singleton_method(:description) { 'A test tool' }
          define_singleton_method(:parameters)  { {} }
          define_method(:call) { |**_| raise NotImplementedError }
        end
      end

      it 'passes tool classes to the pipeline' do
        # SSOT v3: dispatch goes through SelectionDispatch; verify the compiled tool definition
        # reaches the callable — executor ToolInjection must compile tool_class into native format.
        captured_tools = nil
        allow(Legion::LLM::Call::SelectionDispatch).to receive(:call).and_wrap_original do |orig, **kw|
          captured_tools = kw[:arguments][:tools]
          orig.call(**kw)
        end

        Legion::LLM.chat(
          messages: [{ role: :user, content: 'use a tool' }],
          tools:    [tool_class]
        )

        # Dispatch-boundary contract: the compiled tool definition crosses the
        # boundary as a canonical ToolDefinition (Hash values would be
        # rejected by the provider funnel).
        expect(captured_tools[:test_tool]).to be_a(Legion::Extensions::Llm::Canonical::ToolDefinition)
        expect(captured_tools[:test_tool].name).to eq('test_tool')
      end
    end
  end

  describe 'chat endpoint pipeline routing (sync fallback)' do
    it 'routes through pipeline when called with message: string' do
      result = Legion::LLM.chat(
        message: 'sync chat message',
        model:   SSOT_TEST_MODEL,
        caller:  { source: 'api', path: '/api/llm/chat' }
      )
      expect(result).to be_a(Legion::LLM::Inference::Response)
    end

    it 'carries content from pipeline response' do
      result = Legion::LLM.chat(message: 'hello from chat endpoint')
      expect(result.message[:content]).to eq('pipeline response')
    end
  end
end

if defined?(Sinatra::Base) && defined?(Legion::LLM::Routes)
  RSpec.describe 'LLM inference API route' do
    let(:test_app) do
      Class.new(Sinatra::Base) do
        set :show_exceptions, false
        set :raise_errors, false
        set :host_authorization, permitted: :any

        register Legion::LLM::Routes
      end
    end

    def app
      test_app
    end

    def post_json(path, payload, headers = {})
      Rack::MockRequest.new(app).post(
        path,
        {
          'CONTENT_TYPE' => 'application/json',
          input: Legion::JSON.dump(payload)
        }.merge(headers)
      )
    end

    def make_pipeline_response(content: 'ok', tools: [], timeline: [], stop_reason: :end_turn, thinking: nil)
      double(
        'pipeline_response',
        message:         { role: :assistant, content: content },
        routing:         { provider: 'anthropic', model: 'claude-test', instance: 'default', tier: :cloud },
        tokens:          Legion::LLM::Usage.new(input_tokens: 7, output_tokens: 3),
        tools:           tools,
        enrichments:     {},
        stop:            { reason: stop_reason },
        timeline:        timeline,
        thinking:        thinking,
        timestamps:      { step_timings: { provider_call: 100, total: 150 } },
        conversation_id: 'conv_test'
      )
    end

    def stub_process_identity(identity: 'matt@example.com', kind: :human, source: :system)
      stub_const('Legion::Identity', Module.new) unless defined?(Legion::Identity)
      process = Module.new do
        class << self
          attr_accessor :canonical_name_value, :kind_value, :source_value

          def canonical_name = @canonical_name_value
          def kind = @kind_value
          def source = @source_value
        end
      end
      process.canonical_name_value = identity
      process.kind_value = kind
      process.source_value = source

      stub_const('Legion::Identity::Process', process)
    end

    before do
      Legion::Settings.merge_settings('llm', Legion::LLM::Settings.default)
      Legion::Settings[:llm][:api][:use_namespaces] = false
      allow(Legion::LLM).to receive(:started?).and_return(true)
    end

    it 'uses server-resolved caller metadata for OpenAI-compatible chat completions' do
      captured = nil
      response = make_pipeline_response
      executor = instance_double('Legion::LLM::Inference::Executor', call: response)
      principal = instance_double(
        'Legion::Identity::Request',
        canonical_name: 'matt@example.com',
        to_caller_hash: {
          requested_by: {
            id:         'principal-123',
            identity:   'matt@example.com',
            type:       :user,
            credential: :session
          }
        }
      )

      allow(Legion::LLM::Inference::Request).to receive(:build) do |**kwargs|
        captured = kwargs
        :req
      end
      allow(Legion::LLM::Inference::Executor).to receive(:new).with(:req).and_return(executor)
      stub_const('Legion::Identity', Module.new) unless defined?(Legion::Identity)
      stub_const('Legion::Identity::Request', Class.new) unless defined?(Legion::Identity::Request)
      allow(Legion::Identity::Request).to receive(:from_env).and_return(principal)

      response = post_json(
        '/v1/chat/completions',
        { model: 'gpt-test', messages: [{ role: 'user', content: 'hello' }] }
      )

      expect(response.status).to eq(200)
      expect(captured[:caller]).to include(source: 'openai_compat', path: '/v1/chat/completions')
      expect(captured[:caller][:requested_by]).to include(
        id:         'principal-123',
        identity:   'matt@example.com',
        type:       :user,
        credential: :session
      )
    end

    it 'accepts string-keyed unified identity caller metadata' do
      captured = nil
      response = make_pipeline_response
      executor = instance_double('Legion::LLM::Inference::Executor', call: response)
      principal = instance_double(
        'Legion::Identity::Request',
        canonical_name: 'matt@example.com',
        to_caller_hash: {
          'requested_by' => {
            'id'         => 'principal-456',
            'identity'   => 'matt@example.com',
            'type'       => 'user',
            'credential' => 'session'
          }
        }
      )

      allow(Legion::LLM::Inference::Request).to receive(:build) do |**kwargs|
        captured = kwargs
        :req
      end
      allow(Legion::LLM::Inference::Executor).to receive(:new).with(:req).and_return(executor)
      stub_const('Legion::Identity', Module.new) unless defined?(Legion::Identity)
      stub_const('Legion::Identity::Request', Class.new) unless defined?(Legion::Identity::Request)
      allow(Legion::Identity::Request).to receive(:from_env).and_return(principal)

      response = post_json(
        '/v1/chat/completions',
        { model: 'gpt-test', messages: [{ role: 'user', content: 'hello' }] }
      )

      expect(response.status).to eq(200)
      expect(captured[:caller][:requested_by]).to include(
        'id'         => 'principal-456',
        'identity'   => 'matt@example.com',
        'type'       => 'user',
        'credential' => 'session'
      )
    end

    it 'streams OpenAI chat completion tool calls before the terminal tool_calls finish reason' do
      tool_call = { id: 'call_git_1', name: 'git', arguments: { command: 'status' } }
      response = make_pipeline_response(content: '', tools: [tool_call], stop_reason: :tool_use)
      executor = instance_double('Legion::LLM::Inference::Executor')

      allow(Legion::LLM::Inference::Request).to receive(:build).and_return(:req)
      allow(Legion::LLM::Inference::Executor).to receive(:new).with(:req).and_return(executor)
      allow(executor).to receive(:stream_preflight!).and_return(nil)
      allow(executor).to receive(:call_stream).and_return(response)

      response = post_json(
        '/v1/chat/completions',
        {
          model:    'gpt-test',
          stream:   true,
          messages: [{ role: 'user', content: 'run git status' }],
          tools:    [{ type: 'function', function: { name: 'git', description: 'Run git', parameters: {} } }]
        },
        'HTTP_ACCEPT' => 'text/event-stream'
      )

      expect(response.status).to eq(200)
      expect(response.body).to include('"tool_calls":[{')
      expect(response.body).to include('"id":"call_git_1"')
      expect(response.body).to include('"name":"git"')
      expect(response.body).to include('"arguments":"{\\"command\\":\\"status\\"}"')
      expect(response.body).to include('"finish_reason":"tool_calls"')
      expect(response.body).to include('data: [DONE]')
    end

    it 'falls back to local process identity when middleware provides generic system caller metadata' do
      captured = nil
      response = make_pipeline_response
      executor = instance_double('Legion::LLM::Inference::Executor', call: response)
      principal = instance_double(
        'Legion::Identity::Request',
        canonical_name: 'system',
        to_caller_hash: {
          requested_by: {
            id:         'system:system',
            identity:   'system',
            type:       :service,
            credential: :system
          }
        }
      )

      allow(Legion::LLM::Inference::Request).to receive(:build) do |**kwargs|
        captured = kwargs
        :req
      end
      allow(Legion::LLM::Inference::Executor).to receive(:new).with(:req).and_return(executor)
      stub_const('Legion::Identity', Module.new) unless defined?(Legion::Identity)
      stub_const('Legion::Identity::Request', Class.new) unless defined?(Legion::Identity::Request)
      allow(Legion::Identity::Request).to receive(:from_env).and_return(principal)
      stub_process_identity

      response = post_json(
        '/api/llm/inference',
        {
          messages: [{ role: 'user', content: 'hello' }],
          caller:   { requested_by: { id: 'santa:claude', identity: 'santa claude', type: 'external' } }
        }
      )

      expect(response.status).to eq(200)
      expect(captured[:caller]).to include(source: 'api', path: '/api/llm/inference')
      expect(captured[:caller][:requested_by]).to eq(
        identity:   'matt@example.com',
        type:       :human,
        credential: :system
      )
    end

    it 'passes requested deferred tools through request metadata' do
      captured = nil
      response = make_pipeline_response
      executor = instance_double('Legion::LLM::Inference::Executor', call: response)

      allow(Legion::LLM::Inference::Request).to receive(:build) do |**kwargs|
        captured = kwargs
        :req
      end
      allow(Legion::LLM::Inference::Executor).to receive(:new).with(:req).and_return(executor)

      response = post_json('/api/llm/inference', {
                             messages:        [{ role: 'user', content: 'hello' }],
                             requested_tools: ['legion.test.extra']
                           })

      expect(response.status).to eq(200)
      expect(captured[:metadata]).to eq(requested_tools: ['legion.test.extra'])
    end

    it 'passes explicit API client tool passthrough metadata' do
      captured = nil
      response = make_pipeline_response
      executor = instance_double('Legion::LLM::Inference::Executor', call: response)

      allow(Legion::LLM::Inference::Request).to receive(:build) do |**kwargs|
        captured = kwargs
        :req
      end
      allow(Legion::LLM::Inference::Executor).to receive(:new).with(:req).and_return(executor)

      response = post_json('/api/llm/inference', {
                             messages:                [{ role: 'user', content: 'hello' }],
                             tools:                   [{ name: 'client_shell', description: 'Client shell', parameters: {} }],
                             client_tool_passthrough: true
                           })

      expect(response.status).to eq(200)
      expect(captured[:metadata]).to include(
        requested_tools:           [],
        client_tool_passthrough:   true,
        client_tool_request_count: 1
      )
    end

    it 'passes explicit API client tool passthrough false metadata' do
      captured = nil
      response = make_pipeline_response
      executor = instance_double('Legion::LLM::Inference::Executor', call: response)

      allow(Legion::LLM::Inference::Request).to receive(:build) do |**kwargs|
        captured = kwargs
        :req
      end
      allow(Legion::LLM::Inference::Executor).to receive(:new).with(:req).and_return(executor)

      response = post_json('/api/llm/inference', {
                             messages:                [{ role: 'user', content: 'hello' }],
                             tools:                   [{ name: 'client_shell', description: 'Client shell', parameters: {} }],
                             client_tool_passthrough: false
                           })

      expect(response.status).to eq(200)
      expect(captured[:metadata]).to include(
        requested_tools:           [],
        client_tool_passthrough:   false,
        client_tool_request_count: 1
      )
    end

    it 'does not set client_tool_passthrough in metadata when flag is absent' do
      captured = nil
      response = make_pipeline_response
      executor = instance_double('Legion::LLM::Inference::Executor', call: response)

      allow(Legion::LLM::Inference::Request).to receive(:build) do |**kwargs|
        captured = kwargs
        :req
      end
      allow(Legion::LLM::Inference::Executor).to receive(:new).with(:req).and_return(executor)

      response = post_json('/api/llm/inference', {
                             messages: [{ role: 'user', content: 'hello' }],
                             tools:    [{ name: 'client_shell', description: 'Client shell', parameters: {} }]
                           })

      expect(response.status).to eq(200)
      expect(captured[:metadata]).not_to have_key(:client_tool_passthrough)
    end

    it 'returns sync tool_calls from the pipeline response' do
      tool_call = { id: 'tc_1', name: 'legion_tools', arguments: { query: 'status' } }
      openai_tool_call = {
        id:       'tc_1',
        type:     'function',
        index:    0,
        function: {
          name:      'legion_tools',
          arguments: '{"query":"status"}'
        }
      }
      response = make_pipeline_response(content: 'tool response', tools: [tool_call], stop_reason: :tool_use)
      executor = instance_double('Legion::LLM::Inference::Executor', call: response)
      logger = instance_double('Logger', debug: nil, error: nil, info: nil, warn: nil)

      allow(Legion::LLM::Inference::Request).to receive(:build).and_return(:req)
      allow(Legion::LLM::Inference::Executor).to receive(:new).with(:req).and_return(executor)
      allow_any_instance_of(test_app).to receive(:log).and_return(logger)

      response = post_json('/api/llm/inference', { messages: [{ role: 'user', content: 'use legion tools' }] })

      expect(response.status).to eq(200)
      body = Legion::JSON.load(response.body)
      expect(body[:data][:tool_calls]).to eq([openai_tool_call])
      expect(body[:data][:stop_reason]).to eq('tool_use')
      expect(body[:data][:requires_tool_result]).to be true
      expect(logger).to have_received(:debug).with(
        include(
          '[llm][api][inference] action=response_payload',
          'stream=false',
          'kind=json_response',
          '"tool_calls":[{"id":"tc_1","type":"function","index":0,' \
          '"function":{"name":"legion_tools","arguments":"{\\"query\\":\\"status\\"}"}}]'
        )
      )
    end

    it 'flattens structured sync content blocks into text' do
      content_blocks = [
        { type: 'text', text: 'plain ' },
        { type: 'tool_use', id: 'tc_1', name: 'legion_tools', input: { query: 'status' } },
        { 'type' => 'text', 'text' => 'reply' }
      ]
      response = make_pipeline_response(content: content_blocks)
      executor = instance_double('Legion::LLM::Inference::Executor', call: response)

      allow(Legion::LLM::Inference::Request).to receive(:build).and_return(:req)
      allow(Legion::LLM::Inference::Executor).to receive(:new).with(:req).and_return(executor)

      response = post_json('/api/llm/inference', { messages: [{ role: 'user', content: 'hello' }] })

      expect(response.status).to eq(200)
      body = Legion::JSON.load(response.body)
      expect(body[:data][:content]).to eq('plain reply')
    end

    it 'returns thinking separately only when explicitly requested' do
      response = make_pipeline_response(
        content:  'Hello! How can I help you today?',
        thinking: { content: 'The user said "hello".', enabled: true }
      )
      executor = instance_double('Legion::LLM::Inference::Executor', call: response)

      allow(Legion::LLM::Inference::Request).to receive(:build).and_return(:req)
      allow(Legion::LLM::Inference::Executor).to receive(:new).with(:req).and_return(executor)

      default_response = post_json('/api/llm/inference', { messages: [{ role: 'user', content: 'hello' }] })
      default_body = Legion::JSON.load(default_response.body)
      expect(default_body[:data]).not_to have_key(:thinking)

      thinking_response = post_json('/api/llm/inference', {
                                      messages:         [{ role: 'user', content: 'hello' }],
                                      include_thinking: true
                                    })
      thinking_body = Legion::JSON.load(thinking_response.body)
      expect(thinking_body[:data][:content]).to eq('Hello! How can I help you today?')
      expect(thinking_body[:data][:thinking]).to eq(content: 'The user said "hello".', enabled: true)
    end

    it 'streams text and tool events for daemon consumers' do
      tool_call = { id: 'tc_1', name: 'legion_tools', arguments: { query: 'status' } }
      timeline = [
        {
          key:    'tool:execute:legion_tools',
          detail: 'ok via mcp',
          data:   { tool_call_id: 'tc_1', arguments: { query: 'status' }, source: 'mcp:legion', status: 'ok' }
        },
        {
          key:    'tool:result:legion_tools',
          detail: 'done',
          data:   { tool_call_id: 'tc_1', status: 'ok', result: { ok: true } }
        }
      ]
      response = make_pipeline_response(content: 'Hello from pipeline', tools: [tool_call], timeline: timeline)
      executor = instance_double('Legion::LLM::Inference::Executor', tool_event_handler: nil)
      allow(executor).to receive(:tool_event_handler=)

      allow(Legion::LLM::Inference::Request).to receive(:build).and_return(:req)
      allow(Legion::LLM::Inference::Executor).to receive(:new).with(:req).and_return(executor)
      allow(executor).to receive(:stream_preflight!).and_return(nil)
      allow(executor).to receive(:call_stream) do |&block|
        block&.call('Hello ')
        block&.call('from pipeline')
        response
      end

      response = post_json(
        '/api/llm/inference',
        { messages: [{ role: 'user', content: 'stream me' }], stream: true },
        'HTTP_ACCEPT' => 'text/event-stream'
      )

      expect(response.status).to eq(200)
      expect(response.content_type).to include('text/event-stream')
      expect(response.body).to include('event: text-delta')
      expect(response.body).to include('event: tool-progress')
      expect(response.body).to include('event: tool-result')
      expect(response.body).to include('event: done')
    end

    it 'returns client tool calls in done without live tool events when the server does not execute them' do
      tool_call = { id: 'call_client_1', name: 'web_search', arguments: { query: 'legion tools' } }
      response = make_pipeline_response(content: '', tools: [tool_call], stop_reason: :tool_use)
      executor = instance_double('Legion::LLM::Inference::Executor', tool_event_handler: nil)
      logger = instance_double('Logger', debug: nil, error: nil, info: nil, warn: nil)
      allow(executor).to receive(:tool_event_handler=)

      allow(Legion::LLM::Inference::Request).to receive(:build).and_return(:req)
      allow(Legion::LLM::Inference::Executor).to receive(:new).with(:req).and_return(executor)
      allow(executor).to receive(:stream_preflight!).and_return(nil)
      allow(executor).to receive(:call_stream).and_return(response)
      allow_any_instance_of(test_app).to receive(:log).and_return(logger)

      response = post_json(
        '/api/llm/inference',
        { messages: [{ role: 'user', content: 'search the web' }], stream: true },
        'HTTP_ACCEPT' => 'text/event-stream'
      )

      expect(response.status).to eq(200)
      expect(response.body).not_to include('event: tool-call')
      expect(response.body).to include('"tool_calls":[{')
      expect(response.body).to include('"id":"call_client_1"')
      expect(response.body).to include('"type":"function"')
      expect(response.body).to include('"function":{"name":"web_search","arguments":"{\\"query\\":\\"legion tools\\"}"}')
      expect(response.body).to include('"stop_reason":"tool_use"')
      expect(response.body).to include('"requires_tool_result":true')
      expect(response.body).to include('event: done')
      expect(logger).to have_received(:debug).with(
        include(
          '[llm][api][inference] action=response_payload',
          'stream=true',
          'kind=sse_done',
          '"tool_calls":[{"id":"call_client_1","type":"function","index":0,' \
          '"function":{"name":"web_search","arguments":"{\\"query\\":\\"legion tools\\"}"}}]'
        )
      )
    end

    it 'streams native tool errors when executor tool events report failure' do
      response = make_pipeline_response(content: 'fallback answer')
      executor = instance_double('Legion::LLM::Inference::Executor', tool_event_handler: nil)
      handler = nil
      allow(executor).to receive(:tool_event_handler=) { |callable| handler = callable }

      allow(Legion::LLM::Inference::Request).to receive(:build).and_return(:req)
      allow(Legion::LLM::Inference::Executor).to receive(:new).with(:req).and_return(executor)
      allow(executor).to receive(:stream_preflight!).and_return(nil)
      allow(executor).to receive(:call_stream) do |&block|
        handler.call(
          type:         :tool_result,
          tool_call_id: 'tc_error',
          tool_name:    'ruby',
          result:       'command failed',
          status:       :error
        )
        block&.call('fallback answer')
        response
      end

      response = post_json(
        '/api/llm/inference',
        { messages: [{ role: 'user', content: 'run git status' }], stream: true },
        'HTTP_ACCEPT' => 'text/event-stream'
      )

      expect(response.status).to eq(200)
      expect(response.body).to include('event: tool-error')
      expect(response.body).to include('"toolName":"ruby"')
      expect(response.body).to include('"status":"error"')
    end

    it 'flattens structured streaming content blocks into text deltas' do
      response = make_pipeline_response(content: 'Plain reply')
      executor = instance_double('Legion::LLM::Inference::Executor', tool_event_handler: nil)
      allow(executor).to receive(:tool_event_handler=)

      allow(Legion::LLM::Inference::Request).to receive(:build).and_return(:req)
      allow(Legion::LLM::Inference::Executor).to receive(:new).with(:req).and_return(executor)
      allow(executor).to receive(:stream_preflight!).and_return(nil)
      allow(executor).to receive(:call_stream) do |&block|
        block&.call(double('chunk1', content: [{ type: 'text', text: 'Plain ' }]))
        block&.call(double('chunk2', content: [{ type: 'tool_use', id: 'tc_1', name: 'legion_tools' }]))
        block&.call(double('chunk3', content: [{ 'type' => 'text', 'text' => 'reply' }]))
        response
      end

      response = post_json(
        '/api/llm/inference',
        { messages: [{ role: 'user', content: 'stream me' }], stream: true },
        'HTTP_ACCEPT' => 'text/event-stream'
      )

      expect(response.status).to eq(200)
      expect(response.body).to include('data: {"delta":"Plain "}')
      expect(response.body).to include('data: {"delta":"reply"}')
      expect(response.body).to include('"content":"Plain reply"')
      expect(response.body).not_to include('tool_use')
    end

    it 'hides thinking deltas from streaming callers by default' do
      response = make_pipeline_response(content: 'answer')
      executor = instance_double('Legion::LLM::Inference::Executor', tool_event_handler: nil)
      allow(executor).to receive(:tool_event_handler=)

      allow(Legion::LLM::Inference::Request).to receive(:build).and_return(:req)
      allow(Legion::LLM::Inference::Executor).to receive(:new).with(:req).and_return(executor)
      allow(executor).to receive(:stream_preflight!).and_return(nil)
      allow(executor).to receive(:call_stream) do |&block|
        block&.call(double('thinking_chunk', content: nil, thinking: 'reasoning...'))
        block&.call(double('text_chunk', content: 'answer', thinking: nil))
        response
      end

      response = post_json(
        '/api/llm/inference',
        { messages: [{ role: 'user', content: 'think first' }], stream: true },
        'HTTP_ACCEPT' => 'text/event-stream'
      )

      expect(response.status).to eq(200)
      expect(response.body).not_to include('event: thinking-delta')
      expect(response.body).not_to include('reasoning...')
      expect(response.body).to include('"content":"answer"')
      expect(response.body).not_to include('"content":"reasoning...answer"')
    end

    it 'emits thinking deltas only when explicitly requested' do
      response = make_pipeline_response(content: 'answer')
      executor = instance_double('Legion::LLM::Inference::Executor', tool_event_handler: nil)
      allow(executor).to receive(:tool_event_handler=)

      allow(Legion::LLM::Inference::Request).to receive(:build).and_return(:req)
      allow(Legion::LLM::Inference::Executor).to receive(:new).with(:req).and_return(executor)
      allow(executor).to receive(:stream_preflight!).and_return(nil)
      allow(executor).to receive(:call_stream) do |&block|
        block&.call(double('thinking_chunk', content: nil, thinking: 'reasoning...'))
        block&.call(double('text_chunk', content: 'answer', thinking: nil))
        response
      end

      response = post_json(
        '/api/llm/inference',
        { messages: [{ role: 'user', content: 'think first' }], stream: true, include_thinking: true },
        'HTTP_ACCEPT' => 'text/event-stream'
      )

      expect(response.status).to eq(200)
      expect(response.body).to include('event: thinking-delta')
      expect(response.body).to include('data: {"delta":"reasoning..."}')
      expect(response.body).to include('"content":"answer"')
    end
  end
end
