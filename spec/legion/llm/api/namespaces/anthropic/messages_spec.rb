# frozen_string_literal: true

require 'spec_helper'
require 'rack/test'
require 'sinatra/base'
require 'sinatra/namespace'
require 'legion/llm/api/namespaces/helpers'
require 'legion/llm/api/namespaces/anthropic/messages'

RSpec.describe 'Namespaces::Anthropic::Messages' do
  include Rack::Test::Methods

  let(:app) do
    Class.new(Sinatra::Base) do
      set :host_authorization, permitted: :any
      register Sinatra::Namespace
      helpers Legion::LLM::API::Namespaces::Helpers
      namespace('/v1/messages') { register Legion::LLM::API::Namespaces::Anthropic::Messages }
    end
  end

  let(:mock_response) do
    instance_double(
      Legion::LLM::Inference::Response,
      message:         { content: 'Hello! How can I help you?' },
      routing:         { model: 'claude-sonnet-4-6', provider: :anthropic },
      tokens:          { input: 10, output: 8 },
      tools:           [],
      stop:            { reason: 'end_turn' },
      thinking:        nil,
      timestamps:      {},
      timeline:        [],
      conversation_id: nil,
      request_id:      nil
    )
  end

  before do
    allow(Legion::LLM).to receive(:started?).and_return(true)
    allow(Legion::LLM::Inference::Request).to receive(:build).and_call_original
  end

  describe 'POST /v1/messages (non-streaming)' do
    let(:request_body) do
      {
        model:      'claude-sonnet-4-6',
        messages:   [{ role: 'user', content: 'Hello' }],
        max_tokens: 1024
      }
    end

    before do
      mock_executor = instance_double(Legion::LLM::Inference::Executor)
      allow(Legion::LLM::Inference::Executor).to receive(:new).and_return(mock_executor)
      allow(mock_executor).to receive(:call).and_return(mock_response)
    end

    it 'returns Anthropic message format' do
      post '/v1/messages', Legion::JSON.dump(request_body), 'CONTENT_TYPE' => 'application/json'
      expect(last_response.status).to eq(200)
      body = Legion::JSON.load(last_response.body)
      expect(body[:type]).to eq('message')
      expect(body[:role]).to eq('assistant')
      expect(body[:content]).to be_an(Array)
      expect(body[:content].first[:type]).to eq('text')
      expect(body[:model]).to eq('claude-sonnet-4-6')
      expect(body[:stop_reason]).to eq('end_turn')
      expect(body[:usage]).to have_key(:input_tokens)
      expect(body[:usage]).to have_key(:output_tokens)
    end

    # NOTE: model is optional for auto-routing — the executor selects a default.
    # Only messages and max_tokens are required by the Anthropic namespace route.

    it 'requires messages field' do
      post '/v1/messages', Legion::JSON.dump(request_body.except(:messages)), 'CONTENT_TYPE' => 'application/json'
      expect(last_response.status).to eq(400)
    end

    it 'requires max_tokens field' do
      post '/v1/messages', Legion::JSON.dump(request_body.except(:max_tokens)), 'CONTENT_TYPE' => 'application/json'
      expect(last_response.status).to eq(400)
    end

    it 'accepts system as top-level param' do
      body_with_system = request_body.merge(system: 'You are a helpful assistant.')
      post '/v1/messages', Legion::JSON.dump(body_with_system), 'CONTENT_TYPE' => 'application/json'
      expect(last_response.status).to eq(200)
    end

    it 'accepts tools with input_schema' do
      body_with_tools = request_body.merge(
        tools: [{ name: 'get_weather', description: 'Get weather', input_schema: { type: 'object', properties: { city: { type: 'string' } } } }]
      )
      post '/v1/messages', Legion::JSON.dump(body_with_tools), 'CONTENT_TYPE' => 'application/json'
      expect(last_response.status).to eq(200)
    end

    it 'returns 401 for AuthError' do
      mock_executor = instance_double(Legion::LLM::Inference::Executor)
      allow(Legion::LLM::Inference::Executor).to receive(:new).and_return(mock_executor)
      allow(mock_executor).to receive(:call).and_raise(Legion::LLM::AuthError.new('invalid key'))

      post '/v1/messages', Legion::JSON.dump(request_body), 'CONTENT_TYPE' => 'application/json'
      expect(last_response.status).to eq(401)
      body = Legion::JSON.load(last_response.body)
      expect(body[:type]).to eq('error')
      expect(body[:error][:type]).to eq('authentication_error')
    end

    it 'returns 429 for RateLimitError' do
      mock_executor = instance_double(Legion::LLM::Inference::Executor)
      allow(Legion::LLM::Inference::Executor).to receive(:new).and_return(mock_executor)
      allow(mock_executor).to receive(:call).and_raise(Legion::LLM::RateLimitError.new('slow down'))

      post '/v1/messages', Legion::JSON.dump(request_body), 'CONTENT_TYPE' => 'application/json'
      expect(last_response.status).to eq(429)
      body = Legion::JSON.load(last_response.body)
      expect(body[:error][:type]).to eq('rate_limit_error')
    end

    it 'returns 529 for ProviderDown' do
      mock_executor = instance_double(Legion::LLM::Inference::Executor)
      allow(Legion::LLM::Inference::Executor).to receive(:new).and_return(mock_executor)
      allow(mock_executor).to receive(:call).and_raise(Legion::LLM::ProviderDown.new('overloaded'))

      post '/v1/messages', Legion::JSON.dump(request_body), 'CONTENT_TYPE' => 'application/json'
      expect(last_response.status).to eq(529)
      body = Legion::JSON.load(last_response.body)
      expect(body[:error][:type]).to eq('overloaded_error')
    end
  end

  describe 'POST /v1/messages (streaming)' do
    let(:mock_executor) { instance_double(Legion::LLM::Inference::Executor) }

    let(:request_body) do
      {
        model:      'claude-sonnet-4-6',
        messages:   [{ role: 'user', content: 'Hello' }],
        max_tokens: 1024,
        stream:     true
      }
    end

    before do
      allow(Legion::LLM::Inference::Executor).to receive(:new).and_return(mock_executor)
      allow(mock_executor).to receive(:call_stream).and_yield(
        double(content: 'Hello', thinking: nil, respond_to?: true)
      ).and_return(mock_response)
    end

    it 'returns text/event-stream content type' do
      post '/v1/messages', Legion::JSON.dump(request_body),
           'CONTENT_TYPE' => 'application/json',
           'HTTP_ACCEPT'  => 'text/event-stream'
      expect(last_response.content_type).to include('text/event-stream')
    end

    # message_start is emitted BEFORE call_stream, so it is always first.
    it 'emits message_start event first' do
      post '/v1/messages', Legion::JSON.dump(request_body),
           'CONTENT_TYPE' => 'application/json',
           'HTTP_ACCEPT'  => 'text/event-stream'
      events = last_response.body.scan(/^event: (.+)$/).flatten
      expect(events.first).to eq('message_start')
    end

    it 'emits content_block_start and ping before content_block_delta' do
      post '/v1/messages', Legion::JSON.dump(request_body),
           'CONTENT_TYPE' => 'application/json',
           'HTTP_ACCEPT'  => 'text/event-stream'
      events = last_response.body.scan(/^event: (.+)$/).flatten
      delta_idx = events.index('content_block_delta')
      expect(events.index('content_block_start')).to be < delta_idx
      expect(events.index('ping')).to be < delta_idx
    end

    it 'emits message_stop event last' do
      post '/v1/messages', Legion::JSON.dump(request_body),
           'CONTENT_TYPE' => 'application/json',
           'HTTP_ACCEPT'  => 'text/event-stream'
      events = last_response.body.scan(/^event: (.+)$/).flatten
      expect(events.last).to eq('message_stop')
    end

    it 'emits content_block_delta for text chunks' do
      post '/v1/messages', Legion::JSON.dump(request_body),
           'CONTENT_TYPE' => 'application/json',
           'HTTP_ACCEPT'  => 'text/event-stream'
      expect(last_response.body).to include('event: content_block_delta')
      expect(last_response.body).to include('text_delta')
    end

    it 'emits thinking blocks in streaming when emit_thinking_blocks is enabled (default)' do
      allow(mock_executor).to receive(:call_stream).and_yield(
        double(content: nil, thinking: 'internal reasoning', respond_to?: true)
      ).and_return(mock_response)

      post '/v1/messages', Legion::JSON.dump(request_body),
           'CONTENT_TYPE' => 'application/json',
           'HTTP_ACCEPT'  => 'text/event-stream'

      expect(last_response.body).to include('event: message_stop')
      expect(last_response.body).not_to include('Model returned empty response')
    end

    it 'emits ping event' do
      post '/v1/messages', Legion::JSON.dump(request_body),
           'CONTENT_TYPE' => 'application/json',
           'HTTP_ACCEPT'  => 'text/event-stream'
      expect(last_response.body).to include('event: ping')
    end
  end
end
