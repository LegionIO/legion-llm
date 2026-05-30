# frozen_string_literal: true

require 'spec_helper'
require 'rack/test'
require 'sinatra/base'
require 'sinatra/namespace'

RSpec.describe 'Legion::LLM::API::Namespaces::Native::Inference' do
  include Rack::Test::Methods

  before do
    require 'legion/llm/api/shared_helpers'
    require 'legion/llm/api/namespaces/helpers'
    require 'legion/llm/api/translators/openai_response'
    require 'legion/llm/api/namespaces/native/inference'
  end

  let(:app) do
    Class.new(Sinatra::Base) do
      set :host_authorization, permitted: :any
      register Sinatra::Namespace
      helpers Legion::LLM::API::Namespaces::Helpers

      namespace '/api/llm/inference' do
        register Legion::LLM::API::Namespaces::Native::Inference
      end
    end
  end

  let(:mock_pipeline_response) do
    double(
      'Inference::Response',
      message:         { content: 'Hello, world!' },
      routing:         { model: 'llama3.2', provider: 'ollama', instance: 'local', tier: 'local' },
      tokens:          { input: 15, output: 25 },
      stop:            double('Stop', dig: 'end_turn'),
      conversation_id: 'conv-abc',
      enrichments:     nil,
      timeline:        [],
      thinking:        nil,
      timestamps:      {}
    )
  end

  let(:mock_executor) do
    instance_double(Legion::LLM::Inference::Executor, call: mock_pipeline_response)
  end

  before do
    allow(Legion::LLM).to receive(:started?).and_return(true)
    allow(Legion::LLM::Inference::Executor).to receive(:new).and_return(mock_executor)
    allow(Legion::LLM::API::Translators::OpenAIResponse).to receive(:build_tool_calls).and_return([])
  end

  describe 'POST /api/llm/inference' do
    let(:valid_body) do
      {
        messages: [{ role: 'user', content: 'Hello' }]
      }
    end

    it 'returns 200 with response payload' do
      post '/api/llm/inference',
           Legion::JSON.dump(valid_body),
           'CONTENT_TYPE' => 'application/json'
      expect(last_response.status).to eq(200)
      result = Legion::JSON.load(last_response.body)
      expect(result[:data][:content]).to eq('Hello, world!')
      expect(result[:data][:model]).to eq('llama3.2')
    end

    it 'returns 400 when messages is missing' do
      post '/api/llm/inference',
           Legion::JSON.dump({ model: 'llama3.2' }),
           'CONTENT_TYPE' => 'application/json'
      expect(last_response.status).to eq(400)
      result = Legion::JSON.load(last_response.body)
      expect(result[:error][:code]).to eq('missing_fields')
    end

    it 'returns 400 when messages is not an array' do
      post '/api/llm/inference',
           Legion::JSON.dump({ messages: 'not an array' }),
           'CONTENT_TYPE' => 'application/json'
      expect(last_response.status).to eq(400)
      result = Legion::JSON.load(last_response.body)
      expect(result[:error][:code]).to eq('invalid_messages')
    end

    it 'passes tools through to the pipeline' do
      body_with_tools = {
        messages: [{ role: 'user', content: 'Hello' }],
        tools:    [{ name: 'get_weather', description: 'Get weather', parameters: { type: 'object' } }]
      }
      expect(Legion::LLM::Inference::Executor).to receive(:new).with(
        an_object_satisfying { |req| req.tools.size == 1 }
      ).and_return(mock_executor)
      post '/api/llm/inference',
           Legion::JSON.dump(body_with_tools),
           'CONTENT_TYPE' => 'application/json'
      expect(last_response.status).to eq(200)
    end

    it 'includes token counts in response' do
      post '/api/llm/inference',
           Legion::JSON.dump(valid_body),
           'CONTENT_TYPE' => 'application/json'
      result = Legion::JSON.load(last_response.body)
      expect(result[:data][:input_tokens]).to eq(15)
      expect(result[:data][:output_tokens]).to eq(25)
    end

    it 'includes conversation_id in response' do
      post '/api/llm/inference',
           Legion::JSON.dump(valid_body),
           'CONTENT_TYPE' => 'application/json'
      result = Legion::JSON.load(last_response.body)
      expect(result[:data][:conversation_id]).to eq('conv-abc')
    end

    it 'returns 503 when LLM not started' do
      allow(Legion::LLM).to receive(:started?).and_return(false)
      post '/api/llm/inference',
           Legion::JSON.dump(valid_body),
           'CONTENT_TYPE' => 'application/json'
      expect(last_response.status).to eq(503)
    end

    it 'returns 401 on AuthError' do
      allow(mock_executor).to receive(:call).and_raise(Legion::LLM::AuthError, 'invalid credentials')
      post '/api/llm/inference',
           Legion::JSON.dump(valid_body),
           'CONTENT_TYPE' => 'application/json'
      expect(last_response.status).to eq(401)
      result = Legion::JSON.load(last_response.body)
      expect(result[:error][:code]).to eq('auth_error')
    end

    it 'returns 429 on RateLimitError' do
      allow(mock_executor).to receive(:call).and_raise(Legion::LLM::RateLimitError, 'rate limited')
      post '/api/llm/inference',
           Legion::JSON.dump(valid_body),
           'CONTENT_TYPE' => 'application/json'
      expect(last_response.status).to eq(429)
      result = Legion::JSON.load(last_response.body)
      expect(result[:error][:code]).to eq('rate_limit')
    end

    it 'returns 413 on TokenBudgetExceeded' do
      allow(mock_executor).to receive(:call).and_raise(Legion::LLM::TokenBudgetExceeded, 'budget exceeded')
      post '/api/llm/inference',
           Legion::JSON.dump(valid_body),
           'CONTENT_TYPE' => 'application/json'
      expect(last_response.status).to eq(413)
    end

    it 'returns 502 on ProviderDown' do
      allow(mock_executor).to receive(:call).and_raise(Legion::LLM::ProviderDown, 'provider down')
      post '/api/llm/inference',
           Legion::JSON.dump(valid_body),
           'CONTENT_TYPE' => 'application/json'
      expect(last_response.status).to eq(502)
    end
  end
end
