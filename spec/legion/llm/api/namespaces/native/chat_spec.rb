# frozen_string_literal: true

require 'spec_helper'
require 'rack/test'
require 'sinatra/base'
require 'sinatra/namespace'

RSpec.describe 'Legion::LLM::API::Namespaces::Native::Chat' do
  include Rack::Test::Methods

  before do
    require 'legion/llm/api/shared_helpers'
    require 'legion/llm/api/namespaces/helpers'
    require 'legion/llm/api/namespaces/native/chat'
  end

  after(:all) do
    if defined?(Legion::LLM::API::Namespaces::Native::Chat::ASYNC_POOL)
      Legion::LLM::API::Namespaces::Native::Chat::ASYNC_POOL.shutdown
      Legion::LLM::API::Namespaces::Native::Chat::ASYNC_POOL.wait_for_termination(5)
    end
  end

  let(:app) do
    Class.new(Sinatra::Base) do
      set :host_authorization, permitted: :any
      register Sinatra::Namespace
      helpers Legion::LLM::API::Namespaces::Helpers

      namespace '/api/llm/chat' do
        register Legion::LLM::API::Namespaces::Native::Chat
      end
    end
  end

  let(:mock_response) do
    double(
      'Inference::Response',
      message:         { content: 'Hello from LegionIO' },
      content:         'Hello from LegionIO',
      routing:         { model: 'llama3.2', provider: 'ollama' },
      tokens:          { input_tokens: 10, output_tokens: 20 },
      conversation_id: 'conv-123'
    )
  end

  before do
    allow(Legion::LLM).to receive(:started?).and_return(true)
    allow(Legion::LLM).to receive(:chat).and_return(mock_response)
    # Disable cache path in tests
    stub_const('Legion::LLM::Cache', Module.new)
    allow(Legion::LLM::Cache).to receive(:const_defined?).with(:Response).and_return(false)
  end

  describe 'POST /api/llm/chat' do
    it 'returns 201 with response content' do
      post '/api/llm/chat',
           Legion::JSON.dump({ message: 'hello' }),
           'CONTENT_TYPE' => 'application/json',
           'HTTP_X_LEGION_SYNC' => 'true'
      expect(last_response.status).to eq(201)
      result = Legion::JSON.load(last_response.body)
      expect(result[:data][:response]).to eq('Hello from LegionIO')
    end

    it 'returns 400 when message is missing' do
      post '/api/llm/chat',
           Legion::JSON.dump({ model: 'llama3.2' }),
           'CONTENT_TYPE' => 'application/json'
      expect(last_response.status).to eq(400)
      result = Legion::JSON.load(last_response.body)
      expect(result[:error][:code]).to eq('missing_fields')
    end

    it 'includes meta with model and token counts' do
      post '/api/llm/chat',
           Legion::JSON.dump({ message: 'hello' }),
           'CONTENT_TYPE' => 'application/json',
           'HTTP_X_LEGION_SYNC' => 'true'
      result = Legion::JSON.load(last_response.body)
      expect(result[:data][:meta]).to be_a(Hash)
    end

    it 'passes model and provider to Legion::LLM.chat' do
      expect(Legion::LLM).to receive(:chat).with(
        hash_including(message: 'hello', model: 'llama3.2', provider: 'anthropic')
      ).and_return(mock_response)
      post '/api/llm/chat',
           Legion::JSON.dump({ message: 'hello', model: 'llama3.2', provider: 'anthropic' }),
           'CONTENT_TYPE' => 'application/json',
           'HTTP_X_LEGION_SYNC' => 'true'
      expect(last_response.status).to eq(201)
    end

    it 'returns 503 when LLM not started' do
      allow(Legion::LLM).to receive(:started?).and_return(false)
      post '/api/llm/chat',
           Legion::JSON.dump({ message: 'hello' }),
           'CONTENT_TYPE' => 'application/json'
      expect(last_response.status).to eq(503)
    end
  end
end
