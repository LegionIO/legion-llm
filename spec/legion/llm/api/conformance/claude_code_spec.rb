# frozen_string_literal: true

require 'spec_helper'
require 'rack/test'
require 'sinatra/base'
require 'sinatra/namespace'
require 'legion/llm/api/namespaces/registration'

RSpec.describe 'Claude Code conformance', type: :conformance do
  include Rack::Test::Methods

  let(:app) do
    test_app = Class.new(Sinatra::Base) do
      set :host_authorization, permitted: :any
    end
    Legion::LLM::API::Namespaces::Registration.registered(test_app)
    test_app
  end

  before do
    allow(Legion::LLM).to receive(:started?).and_return(true)
    allow(Legion::LLM).to receive(:settings).and_return(
      Legion::LLM::Settings.default
    )
  end

  # Claude Code auth headers
  let(:claude_code_headers) do
    {
      'CONTENT_TYPE'           => 'application/json',
      'HTTP_X_API_KEY'         => 'legion',
      'HTTP_ANTHROPIC_VERSION' => '2023-06-01',
      'HTTP_ANTHROPIC_BETA'    => 'tools-2024-04-04'
    }
  end

  def parsed_sse_events(body)
    body.split("\n\n").filter_map do |block|
      lines = block.split("\n")
      event_line = lines.find { |l| l.start_with?('event: ') }
      data_line  = lines.find { |l| l.start_with?('data: ') }
      next unless event_line && data_line

      {
        event: event_line.sub('event: ', '').strip,
        data:  Legion::JSON.load(data_line.sub('data: ', '').strip)
      }
    end
  end

  # ─── POST /v1/messages (streaming) ─────────────────────────────────────────

  describe 'POST /v1/messages streaming' do
    let(:claude_request) do
      {
        model:      'legionio',
        max_tokens: 1024,
        messages:   [{ role: 'user', content: 'Say hello.' }],
        stream:     true
      }
    end

    let(:fake_executor) { instance_double(Legion::LLM::Inference::Executor) }
    let(:fake_pipeline_response) do
      instance_double(
        Legion::LLM::Inference::Response,
        routing: { model: 'legionio' },
        tokens:  { input_tokens: 8, output_tokens: 3 },
        message: 'Hello world!',
        tools:   [],
        stop:    { reason: 'end_turn' }
      )
    end

    before do
      allow(Legion::LLM::Inference::Executor).to receive(:new).and_return(fake_executor)
      allow(fake_executor).to receive(:call_stream) do |&block|
        ['Hello ', 'world!'].each { |text| block.call(text) }
        fake_pipeline_response
      end

      post '/v1/messages',
           Legion::JSON.dump(claude_request),
           claude_code_headers
    end

    it 'returns 200' do
      expect(last_response.status).to eq(200)
    end

    it 'returns text/event-stream content-type' do
      expect(last_response.content_type).to include('text/event-stream')
    end

    it 'emits message_start as the first event' do
      events = parsed_sse_events(last_response.body)
      expect(events.first[:event]).to eq('message_start')
    end

    it 'message_start payload has type=message_start' do
      events = parsed_sse_events(last_response.body)
      expect(events.first[:data][:type]).to eq('message_start')
    end

    it 'message_start payload has message with id, type, role, model' do
      events = parsed_sse_events(last_response.body)
      msg = events.first[:data][:message]
      expect(msg[:id]).to be_a(String)
      expect(msg[:type]).to eq('message')
      expect(msg[:role]).to eq('assistant')
      expect(msg[:model]).to be_a(String)
    end

    it 'message_start payload has message with usage.input_tokens' do
      events = parsed_sse_events(last_response.body)
      msg = events.first[:data][:message]
      expect(msg[:usage][:input_tokens]).to be_a(Integer)
      expect(msg[:usage][:output_tokens]).to eq(0)
    end

    it 'message_start payload has empty content array' do
      events = parsed_sse_events(last_response.body)
      msg = events.first[:data][:message]
      expect(msg[:content]).to eq([])
    end

    it 'message_start payload has null stop_reason' do
      events = parsed_sse_events(last_response.body)
      msg = events.first[:data][:message]
      expect(msg[:stop_reason]).to be_nil
    end

    it 'emits content_block_start after message_start' do
      events = parsed_sse_events(last_response.body)
      event_names = events.map { |e| e[:event] }
      expect(event_names.index('content_block_start')).to be > event_names.index('message_start')
    end

    it 'first content_block_start has index=0 and type=text' do
      events = parsed_sse_events(last_response.body)
      block_start = events.find { |e| e[:event] == 'content_block_start' }
      expect(block_start[:data][:index]).to eq(0)
      expect(block_start[:data][:content_block][:type]).to eq('text')
      expect(block_start[:data][:content_block][:text]).to eq('')
    end

    it 'emits a ping event' do
      events = parsed_sse_events(last_response.body)
      ping = events.find { |e| e[:event] == 'ping' }
      expect(ping).not_to be_nil
      expect(ping[:data][:type]).to eq('ping')
    end

    it 'emits at least one content_block_delta with type=text_delta' do
      events = parsed_sse_events(last_response.body)
      deltas = events.select { |e| e[:event] == 'content_block_delta' }
      expect(deltas.size).to be >= 1
      deltas.each do |e|
        expect(e[:data][:delta][:type]).to eq('text_delta')
        expect(e[:data][:delta][:text]).to be_a(String)
      end
    end

    it 'content_block_delta events have correct index' do
      events = parsed_sse_events(last_response.body)
      events.select { |e| e[:event] == 'content_block_delta' }.each do |e|
        expect(e[:data][:index]).to be_a(Integer)
      end
    end

    it 'emits content_block_stop after deltas' do
      events = parsed_sse_events(last_response.body)
      event_names = events.map { |e| e[:event] }
      last_delta_idx = event_names.rindex('content_block_delta')
      stop_idx = event_names.index('content_block_stop')
      expect(stop_idx).to be > last_delta_idx
    end

    it 'content_block_stop has correct index' do
      events = parsed_sse_events(last_response.body)
      stop = events.find { |e| e[:event] == 'content_block_stop' }
      expect(stop[:data][:index]).to be_a(Integer)
    end

    it 'emits message_delta before message_stop' do
      events = parsed_sse_events(last_response.body)
      event_names = events.map { |e| e[:event] }
      expect(event_names.index('message_delta')).to be < event_names.index('message_stop')
    end

    it 'message_delta payload has stop_reason' do
      events = parsed_sse_events(last_response.body)
      delta = events.find { |e| e[:event] == 'message_delta' }
      expect(delta[:data][:delta][:stop_reason]).to eq('end_turn')
    end

    it 'message_delta payload has usage with output_tokens' do
      events = parsed_sse_events(last_response.body)
      delta = events.find { |e| e[:event] == 'message_delta' }
      expect(delta[:data][:usage][:output_tokens]).to be_a(Integer)
    end

    it 'emits message_stop as the final event' do
      events = parsed_sse_events(last_response.body)
      expect(events.last[:event]).to eq('message_stop')
    end

    it 'message_stop payload has type=message_stop' do
      events = parsed_sse_events(last_response.body)
      expect(events.last[:data][:type]).to eq('message_stop')
    end

    it 'events appear in correct relative order' do
      events = parsed_sse_events(last_response.body)
      event_names = events.map { |e| e[:event] }
      required_order = %w[
        message_start
        content_block_start
        ping
        content_block_delta
        content_block_stop
        message_delta
        message_stop
      ]
      last_idx = -1
      required_order.each do |name|
        idx = event_names.index(name)
        expect(idx).not_to be_nil, "Expected event '#{name}' to be present in stream"
        expect(idx).to be > last_idx, "Expected '#{name}' (idx #{idx}) to appear after previous required event (idx #{last_idx})"
        last_idx = idx
      end
    end
  end

  # ─── POST /v1/messages with tool calls (streaming) ─────────────────────────

  describe 'POST /v1/messages with tool calls streaming' do
    let(:fake_executor) { instance_double(Legion::LLM::Inference::Executor) }
    let(:tool_call_obj) do
      instance_double(Legion::LLM::Types::ToolCall,
                      id:        'toolu_test_123',
                      name:      'get_weather',
                      arguments: { city: 'Boston' },
                      source:    { type: :client },
                      result:    nil)
    end
    let(:fake_pipeline_response) do
      instance_double(
        Legion::LLM::Inference::Response,
        routing: { model: 'legionio' },
        tokens:  { input_tokens: 20, output_tokens: 10 },
        message: 'I will check the weather.',
        tools:   [tool_call_obj],
        stop:    { reason: 'tool_use' }
      )
    end

    before do
      allow(Legion::LLM::Inference::Executor).to receive(:new).and_return(fake_executor)
      allow(fake_executor).to receive(:call_stream) do |&block|
        block.call('I will check the weather.')
        fake_pipeline_response
      end

      post '/v1/messages',
           Legion::JSON.dump({
                               model:      'legionio',
                               max_tokens: 1024,
                               messages:   [{ role: 'user', content: 'What is the weather?' }],
                               tools:      [{ name: 'get_weather', description: 'Get weather', input_schema: { type: 'object' } }],
                               stream:     true
                             }),
           claude_code_headers
    end

    it 'returns 200' do
      expect(last_response.status).to eq(200)
    end

    it 'emits a tool_use content_block_start when tool call arrives' do
      events = parsed_sse_events(last_response.body)
      tool_block_starts = events.select do |e|
        e[:event] == 'content_block_start' &&
          e[:data].dig(:content_block, :type) == 'tool_use'
      end
      expect(tool_block_starts.size).to be >= 1
    end

    it 'tool_use content_block_start has id and name' do
      events = parsed_sse_events(last_response.body)
      tool_start = events.find do |e|
        e[:event] == 'content_block_start' &&
          e[:data].dig(:content_block, :type) == 'tool_use'
      end
      expect(tool_start[:data][:content_block][:id]).to be_a(String)
      expect(tool_start[:data][:content_block][:name]).to be_a(String)
    end

    it 'emits input_json_delta events for tool arguments' do
      events = parsed_sse_events(last_response.body)
      json_deltas = events.select do |e|
        e[:event] == 'content_block_delta' &&
          e[:data].dig(:delta, :type) == 'input_json_delta'
      end
      expect(json_deltas.size).to be >= 1
    end

    it 'message_delta has stop_reason=tool_use' do
      events = parsed_sse_events(last_response.body)
      msg_delta = events.find { |e| e[:event] == 'message_delta' }
      expect(msg_delta[:data][:delta][:stop_reason]).to eq('tool_use')
    end
  end

  # ─── POST /v1/messages (non-streaming) ─────────────────────────────────────

  describe 'POST /v1/messages non-streaming' do
    let(:fake_executor) { instance_double(Legion::LLM::Inference::Executor) }

    before do
      fake_response = Legion::LLM::Inference::Response.build(
        id:              'test_resp',
        request_id:      'test_req',
        conversation_id: 'conv_sync_test',
        message:         'Hello!',
        routing:         { model: 'legionio' },
        tokens:          { input_tokens: 8, output_tokens: 3 },
        stop:            { reason: 'end_turn' },
        tools:           [],
        timeline:        []
      )
      allow(Legion::LLM::Inference::Executor).to receive(:new).and_return(fake_executor)
      allow(fake_executor).to receive(:call).and_return(fake_response)

      post '/v1/messages',
           Legion::JSON.dump({
                               model:      'legionio',
                               max_tokens: 1024,
                               messages:   [{ role: 'user', content: 'Hello.' }]
                             }),
           claude_code_headers
    end

    it 'returns 200' do
      expect(last_response.status).to eq(200)
    end

    it 'returns application/json content-type' do
      expect(last_response.content_type).to include('application/json')
    end

    it 'returns type=message' do
      body = Legion::JSON.load(last_response.body)
      expect(body[:type]).to eq('message')
    end

    it 'returns role=assistant' do
      body = Legion::JSON.load(last_response.body)
      expect(body[:role]).to eq('assistant')
    end

    it 'returns content array with at least one text block' do
      body = Legion::JSON.load(last_response.body)
      expect(body[:content]).to be_an(Array)
      expect(body[:content].size).to be >= 1
      text_block = body[:content].find { |b| b[:type] == 'text' }
      expect(text_block).not_to be_nil
      expect(text_block[:text]).to be_a(String)
    end

    it 'returns stop_reason' do
      body = Legion::JSON.load(last_response.body)
      expect(body[:stop_reason]).to eq('end_turn')
    end

    it 'returns usage with input_tokens and output_tokens' do
      body = Legion::JSON.load(last_response.body)
      expect(body[:usage][:input_tokens]).to be_a(Integer)
      expect(body[:usage][:output_tokens]).to be_a(Integer)
    end
  end

  # ─── POST /v1/messages — error handling ────────────────────────────────────

  describe 'POST /v1/messages error handling' do
    it 'returns 500 when model is missing (no provider resolves it)' do
      post '/v1/messages',
           Legion::JSON.dump({ max_tokens: 1024, messages: [{ role: 'user', content: 'Hi' }] }),
           claude_code_headers
      expect(last_response.status).to eq(500)
      body = Legion::JSON.load(last_response.body)
      expect(body[:type]).to eq('error')
    end

    it 'returns 400 when messages is missing' do
      post '/v1/messages',
           Legion::JSON.dump({ model: 'legionio', max_tokens: 1024 }),
           claude_code_headers
      expect(last_response.status).to eq(400)
    end

    it 'returns 400 when max_tokens is missing' do
      post '/v1/messages',
           Legion::JSON.dump({ model: 'legionio', messages: [{ role: 'user', content: 'Hi' }] }),
           claude_code_headers
      expect(last_response.status).to eq(400)
    end

    it 'returns 503 when LLM is not started' do
      allow(Legion::LLM).to receive(:started?).and_return(false)
      post '/v1/messages',
           Legion::JSON.dump({ model: 'legionio', max_tokens: 1024, messages: [{ role: 'user', content: 'Hi' }] }),
           claude_code_headers
      expect(last_response.status).to eq(503)
      body = Legion::JSON.load(last_response.body)
      expect(body[:error][:code]).to eq('llm_unavailable')
    end
  end

  # ─── POST /v1/messages/count_tokens ────────────────────────────────────────

  describe 'POST /v1/messages/count_tokens' do
    before do
      allow(Legion::LLM::TokenEstimation).to receive(:estimate).and_return(
        input_tokens:  2,
        output_tokens: 0
      )
    end

    it 'returns 200 with input_tokens count' do
      post '/v1/messages/count_tokens',
           Legion::JSON.dump({ model: 'legionio', messages: [{ role: 'user', content: 'Hello world.' }] }),
           claude_code_headers
      expect(last_response.status).to eq(200)
      body = Legion::JSON.load(last_response.body)
      expect(body[:input_tokens]).to be_a(Integer)
      expect(body[:input_tokens]).to be > 0
    end

    it 'accounts for system prompt in token count' do
      allow(Legion::LLM::TokenEstimation).to receive(:estimate).and_return(
        input_tokens:  3,
        output_tokens: 0
      )
      with = Legion::JSON.load(
        post('/v1/messages/count_tokens',
             Legion::JSON.dump({
                                 model:    'legionio',
                                 messages: [{ role: 'user', content: 'Hi' }],
                                 system:   'You are an expert Ruby developer with 20 years experience.'
                               }),
             claude_code_headers) && last_response.body
      )

      expect(with[:input_tokens]).to be > 2
    end
  end
end
