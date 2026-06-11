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
      # Default: provider does not natively support the Responses API (covers vllm, ollama, etc.)
      allow(ex).to receive(:provider_supports_responses?).and_return(false)
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

    context 'when provider does not natively support the Responses API (vllm, ollama, etc.)' do
      it 'returns sync response object via call when stream is false' do
        # executor.call is already stubbed in executor_double with message: { content: 'Hello' }
        post '/v1/responses',
             Legion::JSON.dump({ input: 'Hello', model: 'legionio', stream: false }),
             'CONTENT_TYPE' => 'application/json'
        expect(last_response.status).to eq(200)
        body = Legion::JSON.load(last_response.body)
        expect(body[:object]).to eq('response')
        expect(body[:status]).to eq('completed')
        expect(body[:output]).to be_an(Array)
      end

      it 'streams typed SSE events via call_responses fallback when stream is true' do
        pipeline_response = double('Response',
                                   routing: { model: 'legionio' },
                                   tokens:  { input_tokens: 5, output_tokens: 10 },
                                   tools:   [])
        allow(executor_double).to receive(:call_responses) do |body:, stream:, &block| # rubocop:disable Lint/UnusedBlockArgument
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
        expect(executor_double).to have_received(:call_responses)
      end
    end

    context 'when provider natively supports the Responses API (openai)' do
      before do
        allow(executor_double).to receive(:provider_supports_responses?).and_return(true)
      end

      it 'routes non-streaming through call_responses' do
        native_response = double('Response',
                                 routing: { model: 'legionio' },
                                 tokens:  { input_tokens: 5, output_tokens: 10 },
                                 message: { content: 'Hello native!' },
                                 tools:   [])
        allow(executor_double).to receive(:call_responses).and_return(native_response)
        post '/v1/responses',
             Legion::JSON.dump({ input: 'Hello', model: 'legionio', stream: false }),
             'CONTENT_TYPE' => 'application/json'
        expect(last_response.status).to eq(200)
        expect(executor_double).to have_received(:call_responses).with(body: anything, stream: false)
      end

      it 'routes streaming through call_responses' do
        pipeline_response = double('Response',
                                   routing: { model: 'legionio' },
                                   tokens:  { input_tokens: 5, output_tokens: 10 },
                                   tools:   [])
        allow(executor_double).to receive(:call_responses) do |**, &block|
          block.call(double('Chunk', content: 'Hello '))
          block.call(double('Chunk', content: 'world'))
          pipeline_response
        end
        post '/v1/responses',
             Legion::JSON.dump({ input: 'Hi', model: 'legionio', stream: true }),
             'CONTENT_TYPE' => 'application/json'
        expect(last_response.content_type).to include('text/event-stream')
        expect(last_response.body).to include('event: response.output_text.delta')
        expect(executor_double).not_to have_received(:call_stream)
      end
    end
  end

  describe '.normalize_input_array' do
    subject { Legion::LLM::API::Namespaces::OpenAI::Responses }

    it 'maps developer role to system' do
      result = subject.normalize_input_array([{ role: 'developer', content: 'You are an expert.' }])
      expect(result).to eq([{ role: 'system', content: 'You are an expert.' }])
    end

    it 'preserves standard roles unchanged' do
      result = subject.normalize_input_array([
                                               { role: 'user', content: 'hello' },
                                               { role: 'assistant', content: 'hi' }
                                             ])
      expect(result.map { |m| m[:role] }).to eq(%w[user assistant])
    end

    it 'mixes developer and user roles correctly' do
      result = subject.normalize_input_array([
                                               { role: 'developer', content: 'Be concise.' },
                                               { role: 'user', content: 'explain ruby' }
                                             ])
      expect(result.first[:role]).to eq('system')
      expect(result.last[:role]).to eq('user')
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
      post '/api/llm/inference/v1/responses',
           Legion::JSON.dump({ input: 'Hello', model: 'legionio', stream: false }),
           'CONTENT_TYPE' => 'application/json'
      expect(last_response.status).to eq(200)
      body = Legion::JSON.load(last_response.body)
      expect(body[:object]).to eq('response')
    end
  end
end
