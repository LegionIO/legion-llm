# frozen_string_literal: true

require 'spec_helper'
require 'rack/test'
require 'sinatra/base'
require 'sinatra/namespace'
require 'legion/llm/api/namespaces/helpers'

RSpec.describe 'Namespaces::OpenAI::Conversations::Items' do
  include Rack::Test::Methods

  let(:conv_id) { 'conv_items_test' }

  before { require 'legion/llm/api/namespaces/openai/conversations/items' }

  let(:app) do
    Class.new(Sinatra::Base) do
      set :host_authorization, permitted: :any
      register Sinatra::Namespace
      helpers Legion::Logging::Helper
      helpers Legion::LLM::API::Namespaces::Helpers
      register Legion::LLM::API::Namespaces::OpenAI::Conversations::Items
    end
  end

  before do
    allow(Legion::LLM).to receive(:started?).and_return(true)
    Legion::LLM::Inference::Conversation.reset!
    Legion::LLM::Inference::Conversation.create_conversation(conv_id)
  end

  describe 'POST /v1/conversations/:id/items' do
    it 'appends a message and returns item object' do
      post "/v1/conversations/#{conv_id}/items",
           Legion::JSON.dump({ role: 'user', content: 'Hello world' }),
           'CONTENT_TYPE' => 'application/json'

      expect(last_response.status).to eq(200)
      body = Legion::JSON.load(last_response.body)
      expect(body[:object]).to eq('conversation.item')
      expect(body[:id]).to be_a(String)
      expect(body[:role]).to eq('user')
      expect(body[:content]).to eq('Hello world')
    end

    it 'requires role field' do
      post "/v1/conversations/#{conv_id}/items",
           Legion::JSON.dump({ content: 'Missing role' }),
           'CONTENT_TYPE' => 'application/json'

      expect(last_response.status).to eq(400)
      body = Legion::JSON.load(last_response.body)
      expect(body[:error][:code]).to eq('missing_fields')
    end

    it 'requires content field' do
      post "/v1/conversations/#{conv_id}/items",
           Legion::JSON.dump({ role: 'user' }),
           'CONTENT_TYPE' => 'application/json'

      expect(last_response.status).to eq(400)
    end
  end

  describe 'GET /v1/conversations/:id/items (list)' do
    before do
      Legion::LLM::Inference::Conversation.append(conv_id, role: :user, content: 'Message one')
      Legion::LLM::Inference::Conversation.append(conv_id, role: :assistant, content: 'Reply one')
    end

    it 'returns list of items' do
      get "/v1/conversations/#{conv_id}/items"
      expect(last_response.status).to eq(200)
      body = Legion::JSON.load(last_response.body)
      expect(body[:object]).to eq('list')
      expect(body[:data]).to be_an(Array)
      expect(body[:data].size).to eq(2)
      expect(body[:data].first[:role]).to eq('user')
    end

    it 'respects limit param' do
      get "/v1/conversations/#{conv_id}/items?limit=1"
      body = Legion::JSON.load(last_response.body)
      expect(body[:data].size).to eq(1)
    end
  end

  describe 'GET /v1/conversations/:id/items/:item_id' do
    let(:appended_msg) do
      Legion::LLM::Inference::Conversation.append(conv_id, role: :user, content: 'Find me')
    end

    it 'retrieves item by id' do
      msg = appended_msg
      get "/v1/conversations/#{conv_id}/items/#{msg[:id]}"
      expect(last_response.status).to eq(200)
      body = Legion::JSON.load(last_response.body)
      expect(body[:object]).to eq('conversation.item')
      expect(body[:id]).to eq(msg[:id])
      expect(body[:content]).to eq('Find me')
    end

    it 'returns 404 for unknown item' do
      get "/v1/conversations/#{conv_id}/items/item_does_not_exist"
      expect(last_response.status).to eq(404)
      body = Legion::JSON.load(last_response.body)
      expect(body[:error][:code]).to eq('item_not_found')
    end
  end

  describe 'DELETE /v1/conversations/:id/items/:item_id' do
    let(:msg) { Legion::LLM::Inference::Conversation.append(conv_id, role: :user, content: 'Delete me') }

    it 'tombstones the item' do
      target_id = msg[:id]
      delete "/v1/conversations/#{conv_id}/items/#{target_id}"
      expect(last_response.status).to eq(200)
      body = Legion::JSON.load(last_response.body)
      expect(body[:id]).to eq(target_id)
      expect(body[:deleted]).to be true
    end

    it 'returns 404 for unknown item' do
      delete "/v1/conversations/#{conv_id}/items/ghost_item"
      expect(last_response.status).to eq(404)
    end
  end
end
