# frozen_string_literal: true

require 'spec_helper'
begin
  require 'sinatra/base'
  require 'legion/llm/routes'
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
    dbl = double('RubyLLM::Chat')
    allow(dbl).to receive(:with_tool)
    allow(dbl).to receive(:with_instructions)
    allow(dbl).to receive(:add_message)
    dbl
  end

  let(:mock_response) do
    double('RubyLLM::Message',
           content:       'pipeline response',
           role:          'assistant',
           input_tokens:  8,
           output_tokens: 4,
           model_id:      'test-model')
  end

  before do
    Legion::Settings.merge_settings('llm', Legion::LLM::Settings.default)
    Legion::Settings[:llm][:pipeline_enabled] = true
    Legion::Settings[:llm][:default_model] = 'test-model'
    Legion::Settings[:llm][:default_provider] = :test
    allow(Legion::LLM).to receive(:started?).and_return(true)
    allow(RubyLLM).to receive(:chat).and_return(mock_session)
    allow(mock_session).to receive(:ask).and_return(mock_response)
  end

  describe 'pipeline routing via messages: array' do
    it 'returns a Pipeline::Response when called with messages: array and pipeline enabled' do
      messages = [{ role: :user, content: 'what is legion?' }]
      result = Legion::LLM.chat(
        messages: messages,
        model:    'test-model',
        provider: :test,
        caller:   { source: 'api', path: '/api/llm/inference' }
      )
      expect(result).to be_a(Legion::LLM::Pipeline::Response)
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
        expect(mock_session).to receive(:add_message).exactly(2).times
        expect(mock_session).to receive(:ask).with('tell me more about ruby').and_return(mock_response)

        Legion::LLM.chat(messages: multi_turn_messages)
      end

      it 'returns a Pipeline::Response for multi-turn conversations' do
        allow(mock_session).to receive(:add_message)
        result = Legion::LLM.chat(messages: multi_turn_messages)
        expect(result).to be_a(Legion::LLM::Pipeline::Response)
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
        expect(mock_session).to receive(:with_tool).with(tool_class)
        Legion::LLM.chat(
          messages: [{ role: :user, content: 'use a tool' }],
          tools:    [tool_class]
        )
      end
    end

    context 'when pipeline is disabled' do
      before { Legion::Settings[:llm][:pipeline_enabled] = false }

      it 'does not return a Pipeline::Response' do
        allow(mock_session).to receive(:with_instructions)
        result = Legion::LLM.chat(
          messages: [{ role: :user, content: 'no pipeline' }]
        )
        expect(result).not_to be_a(Legion::LLM::Pipeline::Response)
      end
    end
  end

  describe 'chat endpoint pipeline routing (sync fallback)' do
    it 'routes through pipeline when called with message: string' do
      result = Legion::LLM.chat(
        message:  'sync chat message',
        model:    'test-model',
        provider: :test,
        caller:   { source: 'api', path: '/api/llm/chat' }
      )
      expect(result).to be_a(Legion::LLM::Pipeline::Response)
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

    def make_pipeline_response(content: 'ok', tools: [], timeline: [], stop_reason: :end_turn)
      double(
        'pipeline_response',
        message:         { role: :assistant, content: content },
        routing:         { provider: 'anthropic', model: 'claude-test' },
        tokens:          Legion::LLM::Usage.new(input_tokens: 7, output_tokens: 3),
        tools:           tools,
        enrichments:     {},
        stop:            { reason: stop_reason },
        timeline:        timeline,
        conversation_id: 'conv_test'
      )
    end

    before do
      Legion::Settings.merge_settings('llm', Legion::LLM::Settings.default)
      allow(Legion::LLM).to receive(:started?).and_return(true)
    end

    it 'passes requested deferred tools through request metadata' do
      captured = nil
      response = make_pipeline_response
      executor = instance_double('Legion::LLM::Pipeline::Executor', call: response)

      allow(Legion::LLM::Pipeline::Request).to receive(:build) do |**kwargs|
        captured = kwargs
        :req
      end
      allow(Legion::LLM::Pipeline::Executor).to receive(:new).with(:req).and_return(executor)

      response = post_json('/api/llm/inference', {
                             messages:        [{ role: 'user', content: 'hello' }],
                             requested_tools: ['legion.test.extra']
                           })

      expect(response.status).to eq(200)
      expect(captured[:metadata]).to eq(requested_tools: ['legion.test.extra'])
    end

    it 'returns sync tool_calls from the pipeline response' do
      tool_call = { id: 'tc_1', name: 'legion_tools', arguments: { query: 'status' } }
      response = make_pipeline_response(content: 'tool response', tools: [tool_call], stop_reason: :tool_use)
      executor = instance_double('Legion::LLM::Pipeline::Executor', call: response)

      allow(Legion::LLM::Pipeline::Request).to receive(:build).and_return(:req)
      allow(Legion::LLM::Pipeline::Executor).to receive(:new).with(:req).and_return(executor)

      response = post_json('/api/llm/inference', { messages: [{ role: 'user', content: 'use legion tools' }] })

      expect(response.status).to eq(200)
      body = Legion::JSON.load(response.body)
      expect(body[:data][:tool_calls]).to eq([tool_call])
      expect(body[:data][:stop_reason]).to eq('tool_use')
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
      executor = instance_double('Legion::LLM::Pipeline::Executor')

      allow(Legion::LLM::Pipeline::Request).to receive(:build).and_return(:req)
      allow(Legion::LLM::Pipeline::Executor).to receive(:new).with(:req).and_return(executor)
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
      expect(response.body).to include('event: tool-call')
      expect(response.body).to include('event: tool-result')
      expect(response.body).to include('event: done')
    end
  end
end
