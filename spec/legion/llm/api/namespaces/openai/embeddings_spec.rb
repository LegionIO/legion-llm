# frozen_string_literal: true

require 'spec_helper'
require 'rack/test'
require 'sinatra/base'
require 'sinatra/namespace'
require 'legion/llm/api/namespaces/helpers'
require 'legion/llm/api/translators/openai_response'

RSpec.describe 'Namespaces::OpenAI::Embeddings' do
  include Rack::Test::Methods

  before { require 'legion/llm/api/namespaces/openai/embeddings' }

  let(:app) do
    Class.new(Sinatra::Base) do
      set :host_authorization, permitted: :any
      register Sinatra::Namespace
      helpers Legion::Logging::Helper
      helpers Legion::LLM::API::Namespaces::Helpers
      register Legion::LLM::API::Namespaces::OpenAI::Embeddings
    end
  end

  before do
    allow(Legion::LLM).to receive(:started?).and_return(true)
    allow(Legion::LLM::Settings).to receive(:value).with(:default_model).and_return('legionio')
    allow(Legion::LLM).to receive(:embed).and_return([0.1, 0.2, 0.3])
  end

  describe 'POST /v1/embeddings' do
    it 'returns 400 when input is missing' do
      post '/v1/embeddings', Legion::JSON.dump({ model: 'legionio' }), 'CONTENT_TYPE' => 'application/json'
      expect(last_response.status).to eq(400)
      body = Legion::JSON.load(last_response.body)
      expect(body[:error][:type]).to eq('invalid_request_error')
    end

    it 'returns embedding vector in OpenAI format' do
      post '/v1/embeddings',
           Legion::JSON.dump({ input: 'Hello world', model: 'legionio' }),
           'CONTENT_TYPE' => 'application/json'
      expect(last_response.status).to eq(200)
      body = Legion::JSON.load(last_response.body)
      expect(body[:object]).to eq('list')
      expect(body[:data]).to be_an(Array)
      expect(body[:data].first[:object]).to eq('embedding')
      expect(body[:data].first[:embedding]).to eq([0.1, 0.2, 0.3])
      expect(body[:model]).to eq('legionio')
    end

    it 'handles array input by using first element' do
      post '/v1/embeddings',
           Legion::JSON.dump({ input: ['Hello', 'world'], model: 'legionio' }),
           'CONTENT_TYPE' => 'application/json'
      expect(last_response.status).to eq(200)
      expect(Legion::LLM).to have_received(:embed).with('Hello', model: 'legionio')
    end
  end
end
