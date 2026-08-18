# frozen_string_literal: true

require 'spec_helper'
require 'rack/test'
require 'sinatra/base'
require 'sinatra/namespace'

RSpec.describe 'Legion::LLM::API::Namespaces::Helpers' do
  include Rack::Test::Methods

  before do
    require 'legion/llm/api/shared_helpers'
    require 'legion/llm/api/namespaces/helpers'
  end

  def app
    @app ||= Class.new(Sinatra::Base) do
      set :host_authorization, permitted: :any
      register Sinatra::Namespace
      helpers Legion::LLM::API::Namespaces::Helpers

      get '/test/openai_error' do
        openai_error('bad request', type: 'invalid_request_error', code: 'model_not_found', status_code: 404)
      end

      get '/test/openai_error_nulls' do
        openai_error('input is required', type: 'invalid_request_error', param: 'input', status_code: 400)
      end

      get '/test/anthropic_error' do
        anthropic_error('authentication_error', 'invalid api key', status_code: 401)
      end

      get '/test/detect_client' do
        client = detect_client(env)
        content_type :json
        Legion::JSON.dump({ client: client })
      end

      # Verify shared helpers are available
      post '/test/shared_parse' do
        parse_request_body # from SharedHelpers
        content_type :json
        Legion::JSON.dump({ ok: true })
      end
    end
  end

  describe '#openai_error' do
    it 'returns OpenAI error format' do
      get '/test/openai_error'
      expect(last_response.status).to eq(404)
      result = Legion::JSON.load(last_response.body)
      expect(result[:error][:message]).to eq('bad request')
      expect(result[:error][:type]).to eq('invalid_request_error')
      expect(result[:error][:code]).to eq('model_not_found')
    end

    it 'always carries the complete envelope (param null when not passed)' do
      get '/test/openai_error'
      result = Legion::JSON.load(last_response.body)
      expect(result[:error].key?(:param)).to be(true)
      expect(result[:error].key?(:code)).to be(true)
      expect(result[:error][:param]).to be_nil
    end

    it 'passes param through and nulls code when not passed' do
      get '/test/openai_error_nulls'
      expect(last_response.status).to eq(400)
      result = Legion::JSON.load(last_response.body)
      expect(result[:error][:message]).to eq('input is required')
      expect(result[:error][:type]).to eq('invalid_request_error')
      expect(result[:error][:param]).to eq('input')
      expect(result[:error][:code]).to be_nil
    end
  end

  describe '#anthropic_error' do
    it 'returns Anthropic error format' do
      get '/test/anthropic_error'
      expect(last_response.status).to eq(401)
      result = Legion::JSON.load(last_response.body)
      expect(result[:type]).to eq('error')
      expect(result[:error][:type]).to eq('authentication_error')
      expect(result[:error][:message]).to eq('invalid api key')
    end
  end

  describe '#detect_client' do
    it 'returns :openai by default' do
      get '/test/detect_client'
      result = Legion::JSON.load(last_response.body)
      expect(result[:client]).to eq('openai')
    end

    it 'returns :anthropic when anthropic-version header present' do
      get '/test/detect_client', {}, { 'HTTP_ANTHROPIC_VERSION' => '2023-06-01' }
      result = Legion::JSON.load(last_response.body)
      expect(result[:client]).to eq('anthropic')
    end

    it 'returns :anthropic when x-api-key present without Bearer' do
      get '/test/detect_client', {}, { 'HTTP_X_API_KEY' => 'sk-ant-123' }
      result = Legion::JSON.load(last_response.body)
      expect(result[:client]).to eq('anthropic')
    end

    it 'returns :openai when Bearer auth without anthropic-version (even with x-api-key)' do
      get '/test/detect_client', {}, { 'HTTP_AUTHORIZATION' => 'Bearer sk-1234', 'HTTP_X_API_KEY' => 'some-key' }
      result = Legion::JSON.load(last_response.body)
      expect(result[:client]).to eq('openai')
    end
  end

  describe 'SharedHelpers methods available' do
    it 'includes parse_request_body from SharedHelpers' do
      post '/test/shared_parse', Legion::JSON.dump({}), 'CONTENT_TYPE' => 'application/json'
      expect(last_response.status).to eq(200)
    end
  end
end
