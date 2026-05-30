# frozen_string_literal: true

require 'spec_helper'
require 'rack/test'
require 'sinatra/base'
require 'sinatra/namespace'
require 'legion/llm/api/namespaces/helpers'
require 'legion/llm/vector_store/storage'
require 'legion/llm/api/namespaces/openai/vector_stores/files'

RSpec.describe 'Namespaces::OpenAI::VectorStores::Files' do
  include Rack::Test::Methods

  let(:app) do
    Class.new(Sinatra::Base) do
      set :host_authorization, permitted: :any
      register Sinatra::Namespace
      helpers Legion::LLM::API::Namespaces::Helpers
      helpers Legion::LLM::API::Namespaces::OpenAI::VectorStores::Files
      namespace('/v1/vector_stores/:vector_store_id') do
        register Legion::LLM::API::Namespaces::OpenAI::VectorStores::Files
      end
    end
  end

  let(:mock_data_module) do
    Module.new do
      extend Legion::Logging::Helper

      def self.connected?
        true
      end
    end
  end

  let(:mock_db)  { double('Sequel::Database') }
  let(:mock_ds)  { double('Sequel::Dataset') }
  let(:now_ts)   { 1_748_000_000 }
  let(:store_id) { 'vs_testabcdef0123456789' }

  let(:vsf_row) do
    {
      id:                     'vsf_file0001aabbccdd',
      vector_store_id:        store_id,
      file_id:                'file-abc123',
      status:                 'completed',
      usage_bytes:            1024,
      chunking_strategy_json: '{"type":"auto"}',
      attributes_json:        '{}',
      last_error_json:        nil,
      created_at:             now_ts
    }
  end

  let(:store_row) { { id: store_id, name: 'Test', status: 'completed' } }

  before do
    stub_const('Legion::Data', mock_data_module)
    allow(Legion::LLM).to receive(:started?).and_return(true)
    allow(Legion::LLM::VectorStore::Storage).to receive(:data_available?).and_return(true)
    allow(Legion::LLM::VectorStore::Storage).to receive(:db).and_return(mock_db)
    allow(Legion::LLM::VectorStore::Storage).to receive(:now_ts).and_return(now_ts)
    allow(Legion::LLM::VectorStore::Storage).to receive(:ensure_tables!)
    allow(Legion::LLM::VectorStore::Storage).to receive(:generate_id).with('vsf').and_return('vsf_file0001aabbccdd')

    allow(mock_db).to receive(:[]).and_return(mock_ds)
    allow(mock_ds).to receive(:where).and_return(mock_ds)
    allow(mock_ds).to receive(:first).and_return(vsf_row)
    allow(mock_ds).to receive(:all).and_return([vsf_row])
    allow(mock_ds).to receive(:insert)
    allow(mock_ds).to receive(:update)
    allow(mock_ds).to receive(:delete)
    allow(mock_ds).to receive(:order).and_return(mock_ds)
    allow(mock_ds).to receive(:limit).and_return(mock_ds)
    allow(mock_ds).to receive(:count).and_return(1)

    # Store lookup returns the store row by default
    allow(mock_ds).to receive(:first).with(no_args).and_return(store_row)
  end

  describe 'POST /v1/vector_stores/:id/files' do
    it 'requires file_id' do
      post "/v1/vector_stores/#{store_id}/files",
           Legion::JSON.dump({}),
           'CONTENT_TYPE' => 'application/json'
      expect(last_response.status).to eq(400)
      body = Legion::JSON.load(last_response.body)
      expect(body[:error][:code]).to eq('missing_fields')
    end

    it 'returns 404 when vector store not found' do
      allow(mock_ds).to receive(:first).and_return(nil)
      post '/v1/vector_stores/vs_missing/files',
           Legion::JSON.dump({ file_id: 'file-abc123' }),
           'CONTENT_TYPE' => 'application/json'
      expect(last_response.status).to eq(404)
    end

    it 'attaches the file and returns a vector_store.file object' do
      call_count = 0
      allow(mock_ds).to receive(:first) do
        call_count += 1
        call_count == 1 ? store_row : vsf_row
      end
      allow(mock_db).to receive(:table_exists?).and_return(false)
      allow(Legion::LLM::Call::Embeddings).to receive(:generate_batch).and_return([
                                                                                    { vector: [0.1, 0.2, 0.3], model: 'nomic-embed-text', provider: :ollama }
                                                                                  ])

      post "/v1/vector_stores/#{store_id}/files",
           Legion::JSON.dump({ file_id: 'file-abc123' }),
           'CONTENT_TYPE' => 'application/json'
      expect(last_response.status).to eq(200)
      body = Legion::JSON.load(last_response.body)
      expect(body[:object]).to eq('vector_store.file')
      expect(body[:file_id]).to eq('file-abc123')
      expect(body[:vector_store_id]).to eq(store_id)
    end

    it 'returns 503 when data is unavailable' do
      allow_any_instance_of(app).to receive(:data_subsystem_available?).and_return(false)
      post "/v1/vector_stores/#{store_id}/files",
           Legion::JSON.dump({ file_id: 'file-abc123' }),
           'CONTENT_TYPE' => 'application/json'
      expect(last_response.status).to eq(503)
    end
  end

  describe 'GET /v1/vector_stores/:id/files' do
    it 'lists files attached to the store' do
      get "/v1/vector_stores/#{store_id}/files"
      expect(last_response.status).to eq(200)
      body = Legion::JSON.load(last_response.body)
      expect(body[:object]).to eq('list')
      expect(body[:data]).to be_an(Array)
      expect(body[:data].first[:object]).to eq('vector_store.file')
    end
  end

  describe 'GET /v1/vector_stores/:id/files/:file_id' do
    it 'returns the file record' do
      allow(mock_ds).to receive(:first).and_return(vsf_row)
      get "/v1/vector_stores/#{store_id}/files/vsf_file0001aabbccdd"
      expect(last_response.status).to eq(200)
      body = Legion::JSON.load(last_response.body)
      expect(body[:object]).to eq('vector_store.file')
      expect(body[:id]).to eq('vsf_file0001aabbccdd')
    end

    it 'returns 404 when file not found' do
      allow(mock_ds).to receive(:first).and_return(nil)
      get "/v1/vector_stores/#{store_id}/files/vsf_missing"
      expect(last_response.status).to eq(404)
    end
  end

  describe 'POST /v1/vector_stores/:id/files/:file_id (update attributes)' do
    it 'updates attributes and returns updated file object' do
      allow(mock_ds).to receive(:first).and_return(vsf_row)
      post "/v1/vector_stores/#{store_id}/files/vsf_file0001aabbccdd",
           Legion::JSON.dump({ attributes: { purpose: 'qa' } }),
           'CONTENT_TYPE' => 'application/json'
      expect(last_response.status).to eq(200)
      body = Legion::JSON.load(last_response.body)
      expect(body[:object]).to eq('vector_store.file')
    end

    it 'returns 404 when file not found' do
      allow(mock_ds).to receive(:first).and_return(nil)
      post "/v1/vector_stores/#{store_id}/files/vsf_missing",
           Legion::JSON.dump({}),
           'CONTENT_TYPE' => 'application/json'
      expect(last_response.status).to eq(404)
    end
  end

  describe 'DELETE /v1/vector_stores/:id/files/:file_id' do
    it 'deletes the file record and its chunks' do
      allow(mock_ds).to receive(:first).and_return(vsf_row)
      delete "/v1/vector_stores/#{store_id}/files/vsf_file0001aabbccdd"
      expect(last_response.status).to eq(200)
      body = Legion::JSON.load(last_response.body)
      expect(body[:id]).to eq('vsf_file0001aabbccdd')
      expect(body[:object]).to eq('vector_store.file.deleted')
      expect(body[:deleted]).to be true
    end

    it 'returns 404 when file not found' do
      allow(mock_ds).to receive(:first).and_return(nil)
      delete "/v1/vector_stores/#{store_id}/files/vsf_missing"
      expect(last_response.status).to eq(404)
    end
  end

  describe 'GET /v1/vector_stores/:id/files/:file_id/content' do
    let(:chunk_rows) do
      [
        { chunk_index: 0, text: 'First paragraph of the document.' },
        { chunk_index: 1, text: 'Second paragraph of the document.' }
      ]
    end

    it 'returns the chunked text content' do
      allow(mock_ds).to receive(:first).and_return(vsf_row)
      allow(mock_ds).to receive(:order).and_return(mock_ds)
      allow(mock_ds).to receive(:all).and_return(chunk_rows)
      get "/v1/vector_stores/#{store_id}/files/vsf_file0001aabbccdd/content"
      expect(last_response.status).to eq(200)
      body = Legion::JSON.load(last_response.body)
      expect(body[:object]).to eq('vector_store.file.content')
      expect(body[:data]).to be_an(Array)
      expect(body[:data].first[:text]).to eq('First paragraph of the document.')
    end

    it 'returns 404 when file not found' do
      allow(mock_ds).to receive(:first).and_return(nil)
      get "/v1/vector_stores/#{store_id}/files/vsf_missing/content"
      expect(last_response.status).to eq(404)
    end
  end
end
