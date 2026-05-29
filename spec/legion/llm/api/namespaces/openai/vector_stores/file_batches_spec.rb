# frozen_string_literal: true

require 'spec_helper'
require 'rack/test'
require 'sinatra/base'
require 'sinatra/namespace'
require 'legion/llm/api/namespaces/helpers'
require 'legion/llm/vector_store/storage'
require 'legion/llm/api/namespaces/openai/vector_stores/file_batches'

RSpec.describe 'Namespaces::OpenAI::VectorStores::FileBatches' do
  include Rack::Test::Methods

  let(:app) do
    Class.new(Sinatra::Base) do
      set :host_authorization, permitted: :any
      register Sinatra::Namespace
      helpers Legion::LLM::API::Namespaces::Helpers
      helpers Legion::LLM::API::Namespaces::OpenAI::VectorStores::FileBatches
      namespace('/v1/vector_stores/:vector_store_id') do
        register Legion::LLM::API::Namespaces::OpenAI::VectorStores::FileBatches
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

  let(:batch_id) { 'vsfb_batch0001aabbcc' }

  let(:store_row) do
    { id: store_id, name: 'Test', status: 'completed' }
  end

  let(:batch_row) do
    {
      id:               batch_id,
      vector_store_id:  store_id,
      status:           'completed',
      file_ids_json:    '["file-abc123","file-def456"]',
      file_counts_json: '{"in_progress":0,"completed":2,"failed":0,"cancelled":0,"total":2}',
      created_at:       now_ts
    }
  end

  let(:vsf_rows) do
    [
      { id: 'vsf_aaaa', vector_store_id: store_id, file_id: 'file-abc123', status: 'completed',
        usage_bytes: 512, chunking_strategy_json: '{"type":"auto"}', attributes_json: '{}',
        last_error_json: nil, created_at: now_ts },
      { id: 'vsf_bbbb', vector_store_id: store_id, file_id: 'file-def456', status: 'completed',
        usage_bytes: 512, chunking_strategy_json: '{"type":"auto"}', attributes_json: '{}',
        last_error_json: nil, created_at: now_ts }
    ]
  end

  before do
    stub_const('Legion::Data', mock_data_module)
    allow(Legion::LLM).to receive(:started?).and_return(true)
    allow(Legion::LLM::VectorStore::Storage).to receive(:data_available?).and_return(true)
    allow(Legion::LLM::VectorStore::Storage).to receive(:db).and_return(mock_db)
    allow(Legion::LLM::VectorStore::Storage).to receive(:now_ts).and_return(now_ts)
    allow(Legion::LLM::VectorStore::Storage).to receive(:ensure_tables!)
    allow(Legion::LLM::VectorStore::Storage).to receive(:generate_id).with('vsfb').and_return(batch_id)
    allow(Legion::LLM::VectorStore::Storage).to receive(:generate_id).with('vsf').and_return('vsf_new_001')
    allow(Legion::LLM::VectorStore::Storage).to receive(:generate_id).with('vsc').and_return('vsc_new_001')

    allow(mock_db).to receive(:[]).and_return(mock_ds)
    allow(mock_db).to receive(:table_exists?).and_return(false)
    allow(mock_ds).to receive(:where).and_return(mock_ds)
    allow(mock_ds).to receive(:first).and_return(store_row)
    allow(mock_ds).to receive(:all).and_return(vsf_rows)
    allow(mock_ds).to receive(:insert)
    allow(mock_ds).to receive(:update)
    allow(mock_ds).to receive(:delete)
    allow(mock_ds).to receive(:order).and_return(mock_ds)
    allow(mock_ds).to receive(:limit).and_return(mock_ds)
    allow(mock_ds).to receive(:count).and_return(2)
  end

  describe 'POST /v1/vector_stores/:id/file_batches' do
    it 'requires file_ids' do
      post "/v1/vector_stores/#{store_id}/file_batches",
           Legion::JSON.dump({}),
           'CONTENT_TYPE' => 'application/json'
      expect(last_response.status).to eq(400)
      body = Legion::JSON.load(last_response.body)
      expect(body[:error][:code]).to eq('missing_fields')
    end

    it 'returns 404 when vector store not found' do
      allow(mock_ds).to receive(:first).and_return(nil)
      post "/v1/vector_stores/vs_missing/file_batches",
           Legion::JSON.dump({ file_ids: ['file-abc123'] }),
           'CONTENT_TYPE' => 'application/json'
      expect(last_response.status).to eq(404)
    end

    it 'creates a file batch and returns a vector_store.file_batch object' do
      call_count = 0
      allow(mock_ds).to receive(:first) do
        call_count += 1
        call_count == 1 ? store_row : batch_row
      end

      post "/v1/vector_stores/#{store_id}/file_batches",
           Legion::JSON.dump({ file_ids: ['file-abc123', 'file-def456'] }),
           'CONTENT_TYPE' => 'application/json'
      expect(last_response.status).to eq(200)
      body = Legion::JSON.load(last_response.body)
      expect(body[:object]).to eq('vector_store.file_batch')
      expect(body[:id]).to eq(batch_id)
      expect(body[:vector_store_id]).to eq(store_id)
      expect(body[:file_counts]).to include(:total)
    end

    it 'returns 400 when file_ids is not an array' do
      post "/v1/vector_stores/#{store_id}/file_batches",
           Legion::JSON.dump({ file_ids: 'file-abc123' }),
           'CONTENT_TYPE' => 'application/json'
      expect(last_response.status).to eq(400)
      body = Legion::JSON.load(last_response.body)
      expect(body[:error][:code]).to eq('invalid_file_ids')
    end

    it 'returns 503 when data unavailable' do
      allow_any_instance_of(app).to receive(:data_subsystem_available?).and_return(false)
      post "/v1/vector_stores/#{store_id}/file_batches",
           Legion::JSON.dump({ file_ids: ['file-abc123'] }),
           'CONTENT_TYPE' => 'application/json'
      expect(last_response.status).to eq(503)
    end
  end

  describe 'GET /v1/vector_stores/:id/file_batches/:batch_id' do
    it 'returns the batch object' do
      allow(mock_ds).to receive(:first).and_return(batch_row)
      get "/v1/vector_stores/#{store_id}/file_batches/#{batch_id}"
      expect(last_response.status).to eq(200)
      body = Legion::JSON.load(last_response.body)
      expect(body[:object]).to eq('vector_store.file_batch')
      expect(body[:id]).to eq(batch_id)
      expect(body[:status]).to eq('completed')
    end

    it 'returns 404 when batch not found' do
      allow(mock_ds).to receive(:first).and_return(nil)
      get "/v1/vector_stores/#{store_id}/file_batches/vsfb_missing"
      expect(last_response.status).to eq(404)
    end
  end

  describe 'GET /v1/vector_stores/:id/file_batches/:batch_id/files' do
    it 'returns list of vector_store.file objects in the batch' do
      allow(mock_ds).to receive(:first).and_return(batch_row)
      get "/v1/vector_stores/#{store_id}/file_batches/#{batch_id}/files"
      expect(last_response.status).to eq(200)
      body = Legion::JSON.load(last_response.body)
      expect(body[:object]).to eq('list')
      expect(body[:data]).to be_an(Array)
      expect(body[:data].first[:object]).to eq('vector_store.file')
    end

    it 'returns 404 when batch not found' do
      allow(mock_ds).to receive(:first).and_return(nil)
      get "/v1/vector_stores/#{store_id}/file_batches/vsfb_missing/files"
      expect(last_response.status).to eq(404)
    end
  end

  describe 'POST /v1/vector_stores/:id/file_batches/:batch_id/cancel' do
    it 'cancels an in-progress batch' do
      in_progress_batch = batch_row.merge(status: 'in_progress')
      allow(mock_ds).to receive(:first).and_return(in_progress_batch)
      post "/v1/vector_stores/#{store_id}/file_batches/#{batch_id}/cancel"
      expect(last_response.status).to eq(200)
      body = Legion::JSON.load(last_response.body)
      expect(body[:object]).to eq('vector_store.file_batch')
    end

    it 'returns 400 when trying to cancel a completed batch' do
      allow(mock_ds).to receive(:first).and_return(batch_row)
      post "/v1/vector_stores/#{store_id}/file_batches/#{batch_id}/cancel"
      expect(last_response.status).to eq(400)
      body = Legion::JSON.load(last_response.body)
      expect(body[:error][:code]).to eq('batch_not_cancellable')
    end

    it 'returns 404 when batch not found' do
      allow(mock_ds).to receive(:first).and_return(nil)
      post "/v1/vector_stores/#{store_id}/file_batches/vsfb_missing/cancel"
      expect(last_response.status).to eq(404)
    end
  end
end
