# frozen_string_literal: true

require 'spec_helper'
require 'rack/test'
require 'sinatra/base'
require 'sinatra/namespace'
require 'legion/llm/api/namespaces/helpers'
require 'legion/llm/api/namespaces/anthropic/messages/batches'

RSpec.describe 'Namespaces::Anthropic::Messages::Batches' do
  include Rack::Test::Methods

  let(:app) do
    Class.new(Sinatra::Base) do
      set :host_authorization, permitted: :any
      register Sinatra::Namespace
      helpers Legion::LLM::API::Namespaces::Helpers
      namespace('/v1/messages/batches') { register Legion::LLM::API::Namespaces::Anthropic::Messages::Batches }
    end
  end

  before do
    allow(Legion::LLM).to receive(:started?).and_return(true)
  end

  describe 'POST /v1/messages/batches' do
    it 'creates a batch and returns batch object' do
      body = {
        requests: [
          { custom_id: 'req-1', params: { model: 'claude-sonnet-4-6', max_tokens: 100, messages: [{ role: 'user', content: 'Hi' }] } }
        ]
      }
      post '/v1/messages/batches', Legion::JSON.dump(body), 'CONTENT_TYPE' => 'application/json'
      expect(last_response.status).to eq(200)
      result = Legion::JSON.load(last_response.body)
      expect(result[:type]).to eq('message_batch')
      expect(result[:processing_status]).to eq('in_progress')
      expect(result[:id]).to start_with('batch_')
    end
  end

  describe 'GET /v1/messages/batches' do
    it 'returns paginated batch list' do
      get '/v1/messages/batches'
      expect(last_response.status).to eq(200)
      result = Legion::JSON.load(last_response.body)
      expect(result[:data]).to be_an(Array)
      expect(result).to have_key(:has_more)
    end
  end

  describe 'GET /v1/messages/batches/:id' do
    it 'returns 404 for unknown batch' do
      get '/v1/messages/batches/batch_nonexistent'
      expect(last_response.status).to eq(404)
      result = Legion::JSON.load(last_response.body)
      expect(result[:type]).to eq('error')
    end
  end

  describe 'POST /v1/messages/batches/:id/cancel' do
    it 'returns 404 for unknown batch' do
      post '/v1/messages/batches/batch_nonexistent/cancel'
      expect(last_response.status).to eq(404)
    end
  end

  describe 'DELETE /v1/messages/batches/:id' do
    it 'returns 404 for unknown batch' do
      delete '/v1/messages/batches/batch_nonexistent'
      expect(last_response.status).to eq(404)
    end
  end
end
