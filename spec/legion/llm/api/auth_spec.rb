# frozen_string_literal: true

require 'spec_helper'
require 'rack/test'
require 'sinatra/base'

RSpec.describe 'Legion::LLM::API::Auth' do
  include Rack::Test::Methods

  before do
    require 'legion/llm/api/auth'
  end

  let(:app) do
    Class.new(Sinatra::Base) do
      set :host_authorization, permitted: :any
      helpers Legion::Logging::Helper
      register Legion::LLM::API::Auth

      get '/v1/models' do
        content_type :json
        Legion::JSON.dump({ object: 'list', data: [] })
      end
    end
  end

  context 'when auth is disabled' do
    before do
      allow(Legion::Settings).to receive(:dig).with(:llm, :api, :auth, :enabled).and_return(nil)
    end

    it 'allows requests without any token' do
      get '/v1/models'
      expect(last_response.status).to eq(200)
    end
  end

  context 'when auth is enabled and token is valid' do
    before do
      allow(Legion::Settings).to receive(:dig).with(:llm, :api, :auth, :enabled).and_return(true)
      allow(Legion::Settings).to receive(:dig).with(:llm, :api, :auth, :api_keys).and_return(['valid-key'])
    end

    it 'allows Bearer token requests' do
      get '/v1/models', {}, { 'HTTP_AUTHORIZATION' => 'Bearer valid-key' }
      expect(last_response.status).to eq(200)
    end

    it 'allows x-api-key requests' do
      get '/v1/models', {}, { 'HTTP_X_API_KEY' => 'valid-key' }
      expect(last_response.status).to eq(200)
    end
  end

  context 'when auth is enabled and token is invalid' do
    before do
      allow(Legion::Settings).to receive(:dig).with(:llm, :api, :auth, :enabled).and_return(true)
      allow(Legion::Settings).to receive(:dig).with(:llm, :api, :auth, :api_keys).and_return(['valid-key'])
    end

    it 'returns 401 for bad Bearer token' do
      get '/v1/models', {}, { 'HTTP_AUTHORIZATION' => 'Bearer bad-key' }
      expect(last_response.status).to eq(401)
    end

    it 'returns OpenAI error shape for Bearer token requests' do
      get '/v1/models', {}, { 'HTTP_AUTHORIZATION' => 'Bearer bad-key' }
      expect(last_response.status).to eq(401)
      body = Legion::JSON.load(last_response.body)
      expect(body[:error][:type]).to eq('authentication_error')
      expect(body[:error][:message]).to be_a(String)
      # OpenAI shape: top-level key is :error, NOT :type
      expect(body.keys).to include(:error)
      expect(body.keys).not_to include(:type)
    end

    it 'returns Anthropic error shape for x-api-key + anthropic-version requests' do
      get '/v1/models', {}, {
        'HTTP_X_API_KEY'         => 'bad-key',
        'HTTP_ANTHROPIC_VERSION' => '2023-06-01'
      }
      expect(last_response.status).to eq(401)
      body = Legion::JSON.load(last_response.body)
      # Anthropic shape: top-level :type = 'error', nested :error hash
      expect(body[:type]).to eq('error')
      expect(body[:error][:type]).to eq('authentication_error')
      expect(body[:error][:message]).to be_a(String)
    end
  end
end
