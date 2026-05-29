# frozen_string_literal: true

require 'spec_helper'
require 'rack/test'
require 'sinatra/base'
require 'sinatra/namespace'
require 'legion/llm/api/namespaces/helpers'
require 'legion/llm/vector_store/storage'
require 'legion/llm/api/namespaces/openai/vector_stores'

RSpec.describe 'Namespaces::OpenAI::VectorStores' do
  include Rack::Test::Methods

  let(:app) do
    Class.new(Sinatra::Base) do
      set :host_authorization, permitted: :any
      register Sinatra::Namespace
      helpers Legion::LLM::API::Namespaces::Helpers
      helpers Legion::LLM::API::Namespaces::OpenAI::VectorStores
      namespace('/v1/vector_stores') { register Legion::LLM::API::Namespaces::OpenAI::VectorStores }
    end
  end

  let(:mock_db)   { double('Sequel::Database') }
  let(:mock_ds)   { double('Sequel::Dataset') }
  let(:now_ts)    { 1_748_000_000 }

  let(:store_row) do
    {
      id:             'vs_testabcdef0123456789',
      name:           'Test Store',
      status:         'completed',
      metadata_json:  '{}',
      usage_bytes:    0,
      expires_at:     nil,
      created_at:     now_ts,
      last_active_at: now_ts
    }
  end

  let(:mock_data_module) do
    Module.new do
      extend Legion::Logging::Helper

      def self.connected?
        true
      end
    end
  end

  before do
    stub_const('Legion::Data', mock_data_module)
    allow(Legion::LLM).to receive(:started?).and_return(true)
    allow(Legion::LLM::VectorStore::Storage).to receive(:data_available?).and_return(true)
    allow(Legion::LLM::VectorStore::Storage).to receive(:db).and_return(mock_db)
    allow(Legion::LLM::VectorStore::Storage).to receive(:now_ts).and_return(now_ts)
    allow(Legion::LLM::VectorStore::Storage).to receive(:ensure_tables!)
    allow(Legion::LLM::VectorStore::Storage).to receive(:generate_id).with('vs').and_return('vs_testabcdef0123456789')
    allow(mock_db).to receive(:[]).and_return(mock_ds)
    allow(mock_ds).to receive(:insert)
    allow(mock_ds).to receive(:where).and_return(mock_ds)
    allow(mock_ds).to receive(:first).and_return(store_row)
    allow(mock_ds).to receive(:all).and_return([store_row])
    allow(mock_ds).to receive(:update)
    allow(mock_ds).to receive(:delete)
    allow(mock_ds).to receive(:order).and_return(mock_ds)
    allow(mock_ds).to receive(:limit).and_return(mock_ds)
    allow(mock_ds).to receive(:count).and_return(0)
  end

  describe 'POST /v1/vector_stores' do
    it 'creates a vector store and returns 200 with store object' do
      post '/v1/vector_stores', Legion::JSON.dump({ name: 'Test Store' }), 'CONTENT_TYPE' => 'application/json'
      expect(last_response.status).to eq(200)
      body = Legion::JSON.load(last_response.body)
      expect(body[:object]).to eq('vector_store')
      expect(body[:id]).to eq('vs_testabcdef0123456789')
      expect(body[:name]).to eq('Test Store')
      expect(body[:status]).to be_a(String)
      expect(body[:file_counts]).to include(:total)
      expect(body[:created_at]).to eq(now_ts)
    end

    it 'creates a vector store with no name (name is optional)' do
      post '/v1/vector_stores', Legion::JSON.dump({}), 'CONTENT_TYPE' => 'application/json'
      expect(last_response.status).to eq(200)
    end

    it 'returns 503 when data is unavailable' do
      allow_any_instance_of(app).to receive(:data_subsystem_available?).and_return(false)
      post '/v1/vector_stores', Legion::JSON.dump({ name: 'X' }), 'CONTENT_TYPE' => 'application/json'
      expect(last_response.status).to eq(503)
      body = Legion::JSON.load(last_response.body)
      expect(body[:error][:code]).to eq('data_required')
    end

    it 'returns 503 when LLM is not started' do
      allow(Legion::LLM).to receive(:started?).and_return(false)
      post '/v1/vector_stores', Legion::JSON.dump({}), 'CONTENT_TYPE' => 'application/json'
      expect(last_response.status).to eq(503)
    end
  end

  describe 'GET /v1/vector_stores' do
    it 'lists vector stores' do
      get '/v1/vector_stores'
      expect(last_response.status).to eq(200)
      body = Legion::JSON.load(last_response.body)
      expect(body[:object]).to eq('list')
      expect(body[:data]).to be_an(Array)
      expect(body[:data].first[:object]).to eq('vector_store')
    end

    it 'returns 503 when data unavailable' do
      allow_any_instance_of(app).to receive(:data_subsystem_available?).and_return(false)
      get '/v1/vector_stores'
      expect(last_response.status).to eq(503)
    end
  end

  describe 'GET /v1/vector_stores/:id' do
    it 'returns the store object' do
      get '/v1/vector_stores/vs_testabcdef0123456789'
      expect(last_response.status).to eq(200)
      body = Legion::JSON.load(last_response.body)
      expect(body[:id]).to eq('vs_testabcdef0123456789')
      expect(body[:object]).to eq('vector_store')
    end

    it 'returns 404 when store not found' do
      allow(mock_ds).to receive(:first).and_return(nil)
      get '/v1/vector_stores/vs_missing'
      expect(last_response.status).to eq(404)
      body = Legion::JSON.load(last_response.body)
      expect(body[:error][:type]).to eq('invalid_request_error')
      expect(body[:error][:code]).to eq('not_found')
    end
  end

  describe 'POST /v1/vector_stores/:id (update)' do
    it 'updates the store name and returns updated object' do
      post '/v1/vector_stores/vs_testabcdef0123456789',
           Legion::JSON.dump({ name: 'New Name' }),
           'CONTENT_TYPE' => 'application/json'
      expect(last_response.status).to eq(200)
      body = Legion::JSON.load(last_response.body)
      expect(body[:object]).to eq('vector_store')
    end

    it 'returns 404 when store not found' do
      allow(mock_ds).to receive(:first).and_return(nil)
      post '/v1/vector_stores/vs_missing',
           Legion::JSON.dump({ name: 'X' }),
           'CONTENT_TYPE' => 'application/json'
      expect(last_response.status).to eq(404)
    end
  end

  describe 'DELETE /v1/vector_stores/:id' do
    it 'deletes the store and returns deleted object' do
      delete '/v1/vector_stores/vs_testabcdef0123456789'
      expect(last_response.status).to eq(200)
      body = Legion::JSON.load(last_response.body)
      expect(body[:id]).to eq('vs_testabcdef0123456789')
      expect(body[:object]).to eq('vector_store.deleted')
      expect(body[:deleted]).to be true
    end

    it 'returns 404 when store not found' do
      allow(mock_ds).to receive(:first).and_return(nil)
      delete '/v1/vector_stores/vs_missing'
      expect(last_response.status).to eq(404)
    end
  end

  describe 'POST /v1/vector_stores/:id/search' do
    let(:chunk_row) do
      {
        file_id:              'file-abc',
        vector_store_file_id: 'vsf_123',
        chunk_index:          0,
        text:                 'Ruby is a dynamic language.',
        embedding_json:       Legion::JSON.dump([0.1, 0.2, 0.3])
      }
    end

    before do
      allow(mock_ds).to receive(:select).and_return(mock_ds)
      allow(mock_ds).to receive(:all).and_return([chunk_row])
      allow(Legion::LLM::Call::Embeddings).to receive(:generate).and_return(
        { vector: [0.1, 0.2, 0.3], model: 'nomic-embed-text', provider: :ollama }
      )
    end

    it 'requires query field' do
      post '/v1/vector_stores/vs_testabcdef0123456789/search',
           Legion::JSON.dump({}),
           'CONTENT_TYPE' => 'application/json'
      expect(last_response.status).to eq(400)
      body = Legion::JSON.load(last_response.body)
      expect(body[:error][:code]).to eq('missing_fields')
    end

    it 'returns search results with score and content' do
      post '/v1/vector_stores/vs_testabcdef0123456789/search',
           Legion::JSON.dump({ query: 'dynamic programming language' }),
           'CONTENT_TYPE' => 'application/json'
      expect(last_response.status).to eq(200)
      body = Legion::JSON.load(last_response.body)
      expect(body[:object]).to eq('vector_store.search_results')
      expect(body[:search_query]).to eq('dynamic programming language')
      expect(body[:data]).to be_an(Array)
      result = body[:data].first
      expect(result[:file_id]).to eq('file-abc')
      expect(result[:score]).to be_a(Float)
      expect(result[:content]).to be_an(Array)
      expect(result[:content].first[:type]).to eq('text')
    end

    it 'returns 404 when store not found' do
      allow(mock_ds).to receive(:first).and_return(nil)
      post '/v1/vector_stores/vs_missing/search',
           Legion::JSON.dump({ query: 'test' }),
           'CONTENT_TYPE' => 'application/json'
      expect(last_response.status).to eq(404)
    end

    it 'returns 503 when embedding generation fails' do
      allow(Legion::LLM::Call::Embeddings).to receive(:generate).and_return(
        { vector: nil, error: 'No embedding provider configured' }
      )
      post '/v1/vector_stores/vs_testabcdef0123456789/search',
           Legion::JSON.dump({ query: 'test' }),
           'CONTENT_TYPE' => 'application/json'
      expect(last_response.status).to eq(503)
      body = Legion::JSON.load(last_response.body)
      expect(body[:error][:code]).to eq('embedding_unavailable')
    end
  end
end
