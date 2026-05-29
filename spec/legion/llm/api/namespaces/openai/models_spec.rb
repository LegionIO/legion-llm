# frozen_string_literal: true

require 'spec_helper'
require 'rack/test'
require 'sinatra/base'
require 'sinatra/namespace'
require 'legion/llm/api/namespaces/helpers'
require 'legion/llm/api/translators/openai_response'

RSpec.describe 'Namespaces::OpenAI::Models' do
  include Rack::Test::Methods

  before { require 'legion/llm/api/namespaces/openai/models' }

  let(:app) do
    Class.new(Sinatra::Base) do
      set :host_authorization, permitted: :any
      register Sinatra::Namespace
      helpers Legion::Logging::Helper
      helpers Legion::LLM::API::Namespaces::Helpers
      register Legion::LLM::API::Namespaces::OpenAI::Models
    end
  end

  before do
    allow(Legion::LLM).to receive(:started?).and_return(true)
    allow(Legion::LLM::Inventory).to receive(:offerings).and_return([
                                                                       { model: 'legionio', provider_family: 'legion', type: :inference },
                                                                       { model: 'llama3.2', provider_family: 'ollama', type: :inference }
                                                                     ])
  end

  describe 'GET /v1/models' do
    it 'returns OpenAI model list format' do
      get '/v1/models'
      expect(last_response.status).to eq(200)
      body = Legion::JSON.load(last_response.body)
      expect(body[:object]).to eq('list')
      expect(body[:data]).to be_an(Array)
      ids = body[:data].map { |m| m[:id] }
      expect(ids).to include('legionio')
    end

    it 'deduplicates models with same id' do
      allow(Legion::LLM::Inventory).to receive(:offerings).and_return([
                                                                         { model: 'legionio', provider_family: 'legion', type: :inference },
                                                                         { model: 'legionio', provider_family: 'legion', type: :inference }
                                                                       ])
      get '/v1/models'
      body = Legion::JSON.load(last_response.body)
      expect(body[:data].map { |m| m[:id] }.tally['legionio']).to eq(1)
    end
  end

  describe 'GET /v1/models/:id' do
    it 'returns the model when found' do
      get '/v1/models/legionio'
      expect(last_response.status).to eq(200)
      body = Legion::JSON.load(last_response.body)
      expect(body[:id]).to eq('legionio')
      expect(body[:object]).to eq('model')
    end

    it 'returns 404 for unknown model' do
      get '/v1/models/no-such-model'
      expect(last_response.status).to eq(404)
      body = Legion::JSON.load(last_response.body)
      expect(body[:error][:type]).to eq('invalid_request_error')
      expect(body[:error][:code]).to eq('model_not_found')
    end
  end

  describe 'DELETE /v1/models/:id' do
    it 'returns deleted stub' do
      delete '/v1/models/my-fine-tune'
      expect(last_response.status).to eq(200)
      body = Legion::JSON.load(last_response.body)
      expect(body[:deleted]).to be(true)
      expect(body[:id]).to eq('my-fine-tune')
    end
  end

  describe 'Anthropic client format (anthropic-version header)' do
    it 'GET /v1/models returns Anthropic list format' do
      get '/v1/models', {}, { 'HTTP_ANTHROPIC_VERSION' => '2023-06-01' }
      expect(last_response.status).to eq(200)
      body = Legion::JSON.load(last_response.body)
      expect(body[:has_more]).to eq(false)
      expect(body[:data]).to be_an(Array)
      expect(body[:data].first[:type]).to eq('model')
      expect(body[:data].first[:display_name]).to be_a(String)
      expect(body[:data].first[:created_at]).to be_a(String)
      expect(body.keys).not_to include(:object)
    end

    it 'GET /v1/models/:id returns Anthropic model object' do
      get '/v1/models/legionio', {}, { 'HTTP_ANTHROPIC_VERSION' => '2023-06-01' }
      expect(last_response.status).to eq(200)
      body = Legion::JSON.load(last_response.body)
      expect(body[:id]).to eq('legionio')
      expect(body[:type]).to eq('model')
      expect(body[:display_name]).to be_a(String)
      expect(body.keys).not_to include(:object)
    end
  end
end
