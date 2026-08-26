# frozen_string_literal: true

require 'spec_helper'
require 'rack/test'
require 'sinatra/base'
require 'sinatra/namespace'
require 'legion/llm/api/namespaces/helpers'
require 'legion/llm/api/translators/openai_request'
require 'legion/llm/api/translators/openai_response'

RSpec.describe 'Namespaces::OpenAI::Chat::Completions' do
  include Rack::Test::Methods

  before { require 'legion/llm/api/namespaces/openai/chat/completions' }

  let(:pipeline_response) do
    double('Response',
           routing: { model: 'legionio' },
           tokens:  { input_tokens: 10, output_tokens: 20 },
           message: { content: 'Hello there!' },
           tools:   [],
           stop:    { reason: 'stop' })
  end

  let(:executor_double) do
    double('Executor').tap do |ex|
      allow(ex).to receive(:call).and_return(pipeline_response)
      allow(ex).to receive(:stream_preflight!).and_return(nil)
      allow(ex).to receive(:call_stream).and_return(pipeline_response)
    end
  end

  let(:app) do
    Class.new(Sinatra::Base) do
      set :host_authorization, permitted: :any
      register Sinatra::Namespace
      helpers Legion::Logging::Helper
      helpers Legion::LLM::API::Namespaces::Helpers
      register Legion::LLM::API::Namespaces::OpenAI::Chat::Completions
    end
  end

  before do
    allow(Legion::LLM).to receive(:started?).and_return(true)
    allow(Legion::LLM::Inference::Request).to receive(:build).and_return(double('Request'))
    allow(Legion::LLM::Inference::Executor).to receive(:new).and_return(executor_double)
    Legion::Settings[:llm][:default_model] = 'legionio'
  end

  describe 'POST /v1/chat/completions' do
    it 'returns 400 when messages is missing' do
      post '/v1/chat/completions', Legion::JSON.dump({ model: 'legionio' }), 'CONTENT_TYPE' => 'application/json'
      expect(last_response.status).to eq(400)
      body = Legion::JSON.load(last_response.body)
      expect(body[:error][:type]).to eq('invalid_request_error')
    end

    it 'returns sync ChatCompletion object' do
      post '/v1/chat/completions',
           Legion::JSON.dump({ messages: [{ role: 'user', content: 'Hi' }], model: 'legionio' }),
           'CONTENT_TYPE' => 'application/json'
      expect(last_response.status).to eq(200)
      body = Legion::JSON.load(last_response.body)
      expect(body[:object]).to eq('chat.completion')
      expect(body[:choices]).to be_an(Array)
      expect(body[:choices].first[:message][:role]).to eq('assistant')
    end

    it 'streams data: chunks terminated by data: [DONE]' do
      allow(executor_double).to receive(:stream_preflight!).and_return(nil)
      allow(executor_double).to receive(:call_stream) do |&block|
        # G3/L2: Canonical::Chunk only (the legacy double('Chunk') shape is
        # gone; R15).
        block.call(Legion::Extensions::Llm::Canonical::Chunk.text_delta(delta: 'Hello ', request_id: 'req_oc'))
        block.call(Legion::Extensions::Llm::Canonical::Chunk.text_delta(delta: 'world', request_id: 'req_oc'))
        pipeline_response
      end
      post '/v1/chat/completions',
           Legion::JSON.dump({ messages: [{ role: 'user', content: 'Hi' }], model: 'legionio', stream: true }),
           'CONTENT_TYPE' => 'application/json'
      expect(last_response.content_type).to include('text/event-stream')
      expect(last_response.body).to include('data: {')
      expect(last_response.body).to include('chat.completion.chunk')
      expect(last_response.body).to include('data: [DONE]')
    end
  end

  describe 'GET /v1/chat/completions' do
    it 'returns empty list' do
      get '/v1/chat/completions'
      expect(last_response.status).to eq(200)
      body = Legion::JSON.load(last_response.body)
      expect(body[:object]).to eq('list')
      expect(body[:data]).to eq([])
    end
  end

  describe 'DELETE /v1/chat/completions/:id' do
    it 'returns deleted stub' do
      delete '/v1/chat/completions/chatcmpl-abc'
      expect(last_response.status).to eq(200)
      body = Legion::JSON.load(last_response.body)
      expect(body[:deleted]).to be(true)
    end
  end
end
