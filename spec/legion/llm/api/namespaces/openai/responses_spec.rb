# frozen_string_literal: true

require 'spec_helper'
require 'rack/test'
require 'sinatra/base'
require 'sinatra/namespace'
require 'legion/llm/api/namespaces/helpers'

RSpec.describe 'Namespaces::OpenAI::Responses' do
  include Rack::Test::Methods

  before do
    require 'legion/llm/api/namespaces/openai/responses'
  end

  let(:app) do
    Class.new(Sinatra::Base) do
      set :host_authorization, permitted: :any
      register Sinatra::Namespace
      helpers Legion::Logging::Helper
      helpers Legion::LLM::API::Namespaces::Helpers
      register Legion::LLM::API::Namespaces::OpenAI::Responses
    end
  end

  let(:executor_double) do
    double('Executor').tap do |ex|
      allow(ex).to receive(:call_stream).and_return(
        double('Response', routing: { model: 'legionio' }, tokens: { input_tokens: 5, output_tokens: 10 }, tools: [])
      )
      allow(ex).to receive(:call_responses).and_return(
        double('Response', routing: { model: 'legionio' }, tokens: { input_tokens: 5, output_tokens: 10 },
                           message: { content: 'Hello' }, tools: [])
      )
      allow(ex).to receive(:call).and_return(
        double('Response', routing: { model: 'legionio' }, tokens: { input_tokens: 5, output_tokens: 10 },
                           message: { content: 'Hello' }, tools: [])
      )
    end
  end

  before do
    allow(Legion::LLM).to receive(:started?).and_return(true)
    allow(Legion::LLM::Inference::Request).to receive(:build).and_return(double('Request'))
    allow(Legion::LLM::Inference::Executor).to receive(:new).and_return(executor_double)
    Legion::Settings[:llm][:default_model] = 'legionio'
  end

  describe 'POST /v1/responses' do
    it 'returns 400 when input is missing' do
      post '/v1/responses', Legion::JSON.dump({ model: 'legionio' }), 'CONTENT_TYPE' => 'application/json'
      expect(last_response.status).to eq(400)
      body = Legion::JSON.load(last_response.body)
      expect(body[:error][:type]).to eq('invalid_request_error')
    end

    it 'returns sync response object when stream is false' do
      allow(executor_double).to receive(:call_responses).and_return(
        double('Response',
               routing: { model: 'legionio' },
               tokens:  { input_tokens: 5, output_tokens: 10 },
               message: { content: 'Hello!' },
               tools:   [])
      )
      post '/v1/responses',
           Legion::JSON.dump({ input: 'Hello', model: 'legionio', stream: false }),
           'CONTENT_TYPE' => 'application/json'
      expect(last_response.status).to eq(200)
      body = Legion::JSON.load(last_response.body)
      expect(body[:object]).to eq('response')
      expect(body[:status]).to eq('completed')
      expect(body[:output]).to be_an(Array)
    end

    it 'streams typed SSE events when stream is true' do
      pipeline_response = double('Response',
                                 routing: { model: 'legionio' },
                                 tokens:  { input_tokens: 5, output_tokens: 10 },
                                 tools:   [])
      allow(executor_double).to receive(:call_stream) do |&block|
        block.call(double('Chunk', content: 'Hello '))
        block.call(double('Chunk', content: 'world'))
        pipeline_response
      end
      # Also stub call_responses for streaming path (call_executor prefers it when upstream_body present)
      allow(executor_double).to receive(:call_responses) do |**, &block|
        block.call(double('Chunk', content: 'Hello '))
        block.call(double('Chunk', content: 'world'))
        pipeline_response
      end
      post '/v1/responses',
           Legion::JSON.dump({ input: 'Hi', model: 'legionio', stream: true }),
           'CONTENT_TYPE' => 'application/json'
      expect(last_response.content_type).to include('text/event-stream')
      expect(last_response.body).to include('event: response.created')
      expect(last_response.body).to include('event: response.output_text.delta')
      expect(last_response.body).to include('event: response.completed')
      expect(last_response.body).not_to include('data: [DONE]')
    end
  end

  describe 'GET /v1/responses/:id' do
    it 'returns 404 for unknown id' do
      get '/v1/responses/resp_unknown'
      expect(last_response.status).to eq(404)
    end
  end

  describe 'DELETE /v1/responses/:id' do
    it 'returns deleted stub' do
      delete '/v1/responses/resp_abc'
      expect(last_response.status).to eq(200)
      body = Legion::JSON.load(last_response.body)
      expect(body[:deleted]).to be(true)
      expect(body[:id]).to eq('resp_abc')
    end
  end

  describe 'GET /v1/responses/:id/input_items' do
    it 'returns empty list stub' do
      get '/v1/responses/resp_abc/input_items'
      expect(last_response.status).to eq(200)
      body = Legion::JSON.load(last_response.body)
      expect(body[:object]).to eq('list')
      expect(body[:data]).to eq([])
    end
  end

  describe 'POST /v1/responses/:id/input_tokens/count' do
    it 'returns token count estimate' do
      post '/v1/responses/resp_abc/input_tokens/count',
           Legion::JSON.dump({ input: 'How many tokens?', model: 'legionio' }),
           'CONTENT_TYPE' => 'application/json'
      expect(last_response.status).to eq(200)
      body = Legion::JSON.load(last_response.body)
      expect(body[:input_tokens]).to be_a(Integer)
      expect(body[:input_tokens]).to be > 0
    end
  end

  describe 'POST /api/llm/inference/v1/responses (legacy alias)' do
    it 'returns a response via the legacy path (same as /v1/responses)' do
      allow(executor_double).to receive(:call_responses).and_return(
        double('Response',
               routing: { model: 'legionio' },
               tokens:  { input_tokens: 5, output_tokens: 10 },
               message: { content: 'Hello via legacy path!' },
               tools:   [])
      )
      post '/api/llm/inference/v1/responses',
           Legion::JSON.dump({ input: 'Hello', model: 'legionio', stream: false }),
           'CONTENT_TYPE' => 'application/json'
      expect(last_response.status).to eq(200)
      body = Legion::JSON.load(last_response.body)
      expect(body[:object]).to eq('response')
    end
  end
end
