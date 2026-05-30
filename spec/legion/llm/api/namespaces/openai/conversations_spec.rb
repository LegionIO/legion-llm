# frozen_string_literal: true

require 'spec_helper'
require 'rack/test'
require 'sinatra/base'
require 'sinatra/namespace'
require 'legion/llm/api/namespaces/helpers'

RSpec.describe 'Namespaces::OpenAI::Conversations' do
  include Rack::Test::Methods

  before { require 'legion/llm/api/namespaces/openai/conversations' }

  let(:app) do
    Class.new(Sinatra::Base) do
      set :host_authorization, permitted: :any
      register Sinatra::Namespace
      helpers Legion::Logging::Helper
      helpers Legion::LLM::API::Namespaces::Helpers
      register Legion::LLM::API::Namespaces::OpenAI::Conversations
    end
  end

  before do
    allow(Legion::LLM).to receive(:started?).and_return(true)
    Legion::LLM::Inference::Conversation.reset!
  end

  describe 'POST /v1/conversations' do
    it 'creates a new conversation and returns object' do
      post '/v1/conversations',
           Legion::JSON.dump({ model: 'claude-sonnet-4-6', metadata: { title: 'Test Chat' } }),
           'CONTENT_TYPE' => 'application/json'

      expect(last_response.status).to eq(200)
      body = Legion::JSON.load(last_response.body)
      expect(body[:object]).to eq('conversation')
      expect(body[:id]).to start_with('conv_')
      expect(body[:model]).to eq('claude-sonnet-4-6')
      expect(body[:created_at]).to be_a(Integer)
    end

    it 'creates conversation without metadata' do
      post '/v1/conversations', '{}', 'CONTENT_TYPE' => 'application/json'
      expect(last_response.status).to eq(200)
      body = Legion::JSON.load(last_response.body)
      expect(body[:id]).to start_with('conv_')
    end

    it 'returns 503 when LLM not started' do
      allow(Legion::LLM).to receive(:started?).and_return(false)
      post '/v1/conversations', '{}', 'CONTENT_TYPE' => 'application/json'
      expect(last_response.status).to eq(503)
    end
  end

  describe 'GET /v1/conversations/:id' do
    let(:conv_id) { 'conv_abc123' }

    before do
      Legion::LLM::Inference::Conversation.create_conversation(conv_id)
      Legion::LLM::Inference::Conversation.store_metadata(conv_id, title: 'My Chat', model: 'claude-sonnet-4-6')
    end

    it 'returns conversation metadata' do
      get "/v1/conversations/#{conv_id}"
      expect(last_response.status).to eq(200)
      body = Legion::JSON.load(last_response.body)
      expect(body[:object]).to eq('conversation')
      expect(body[:id]).to eq(conv_id)
    end

    it 'returns 404 for unknown id' do
      get '/v1/conversations/conv_doesnotexist'
      expect(last_response.status).to eq(404)
      body = Legion::JSON.load(last_response.body)
      expect(body[:error][:type]).to eq('invalid_request_error')
      expect(body[:error][:code]).to eq('conversation_not_found')
    end
  end

  describe 'POST /v1/conversations/:id (update)' do
    let(:conv_id) { 'conv_upd001' }

    before do
      Legion::LLM::Inference::Conversation.create_conversation(conv_id)
    end

    it 'updates conversation metadata' do
      post "/v1/conversations/#{conv_id}",
           Legion::JSON.dump({ metadata: { title: 'Updated Title' } }),
           'CONTENT_TYPE' => 'application/json'

      expect(last_response.status).to eq(200)
      body = Legion::JSON.load(last_response.body)
      expect(body[:object]).to eq('conversation')
      expect(body[:id]).to eq(conv_id)
    end

    it 'returns 404 for unknown id' do
      post '/v1/conversations/conv_missing',
           Legion::JSON.dump({ metadata: { title: 'x' } }),
           'CONTENT_TYPE' => 'application/json'
      expect(last_response.status).to eq(404)
    end
  end

  describe 'DELETE /v1/conversations/:id' do
    let(:conv_id) { 'conv_del001' }

    before do
      Legion::LLM::Inference::Conversation.create_conversation(conv_id)
    end

    it 'deletes the conversation and tombstones it' do
      delete "/v1/conversations/#{conv_id}"
      expect(last_response.status).to eq(200)
      body = Legion::JSON.load(last_response.body)
      expect(body[:id]).to eq(conv_id)
      expect(body[:deleted]).to be true

      # Tombstone check: subsequent GET must return 404
      get "/v1/conversations/#{conv_id}"
      expect(last_response.status).to eq(404)
    end

    it 'returns 404 for unknown id' do
      delete '/v1/conversations/conv_ghost'
      expect(last_response.status).to eq(404)
    end
  end
end
