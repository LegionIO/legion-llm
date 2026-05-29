# frozen_string_literal: true

require 'spec_helper'
require 'rack/test'
require 'sinatra/base'
require 'sinatra/namespace'
require 'legion/llm/api/namespaces/helpers'
require 'legion/llm/api/namespaces/anthropic/messages/count_tokens'

RSpec.describe 'Namespaces::Anthropic::Messages::CountTokens' do
  include Rack::Test::Methods

  let(:app) do
    Class.new(Sinatra::Base) do
      set :host_authorization, permitted: :any
      register Sinatra::Namespace
      helpers Legion::LLM::API::Namespaces::Helpers
      namespace('/v1/messages') { register Legion::LLM::API::Namespaces::Anthropic::Messages::CountTokens }
    end
  end

  before do
    allow(Legion::LLM).to receive(:started?).and_return(true)
  end

  describe 'POST /v1/messages/count_tokens' do
    let(:request_body) do
      {
        model:      'claude-sonnet-4-6',
        messages:   [{ role: 'user', content: 'Hello, how are you doing today?' }],
        max_tokens: 1024
      }
    end

    it 'returns input_tokens count' do
      post '/v1/messages/count_tokens', Legion::JSON.dump(request_body), 'CONTENT_TYPE' => 'application/json'
      expect(last_response.status).to eq(200)
      body = Legion::JSON.load(last_response.body)
      expect(body[:input_tokens]).to be_a(Integer)
      expect(body[:input_tokens]).to be > 0
    end

    it 'requires model' do
      post '/v1/messages/count_tokens', Legion::JSON.dump(request_body.except(:model)), 'CONTENT_TYPE' => 'application/json'
      expect(last_response.status).to eq(400)
      body = Legion::JSON.load(last_response.body)
      expect(body[:type]).to eq('error')
      expect(body[:error][:type]).to eq('invalid_request_error')
    end

    it 'requires messages' do
      post '/v1/messages/count_tokens', Legion::JSON.dump(request_body.except(:messages)), 'CONTENT_TYPE' => 'application/json'
      expect(last_response.status).to eq(400)
    end

    it 'includes system in token count' do
      without_system = request_body
      with_system = request_body.merge(system: 'You are a helpful expert in Ruby programming.')

      post '/v1/messages/count_tokens', Legion::JSON.dump(without_system), 'CONTENT_TYPE' => 'application/json'
      count_without = Legion::JSON.load(last_response.body)[:input_tokens]

      post '/v1/messages/count_tokens', Legion::JSON.dump(with_system), 'CONTENT_TYPE' => 'application/json'
      count_with = Legion::JSON.load(last_response.body)[:input_tokens]

      expect(count_with).to be > count_without
    end

    it 'includes tools in token count' do
      body_with_tools = request_body.merge(
        tools: [{ name: 'search', description: 'Search the web', input_schema: { type: 'object', properties: { query: { type: 'string' } } } }]
      )

      post '/v1/messages/count_tokens', Legion::JSON.dump(request_body), 'CONTENT_TYPE' => 'application/json'
      count_without = Legion::JSON.load(last_response.body)[:input_tokens]

      post '/v1/messages/count_tokens', Legion::JSON.dump(body_with_tools), 'CONTENT_TYPE' => 'application/json'
      count_with = Legion::JSON.load(last_response.body)[:input_tokens]

      expect(count_with).to be > count_without
    end
  end
end
