# frozen_string_literal: true

require 'spec_helper'
require 'rack/test'
require 'sinatra/base'
require 'sinatra/namespace'
require 'tmpdir'
require 'legion/llm/api/namespaces/helpers'

RSpec.describe 'Namespaces::OpenAI::Uploads' do
  include Rack::Test::Methods

  let(:tmp_dir) { Dir.mktmpdir }

  before do
    require 'legion/llm/api/namespaces/openai/files'
    require 'legion/llm/api/namespaces/openai/uploads'
  end

  let(:app) do
    Class.new(Sinatra::Base) do
      set :host_authorization, permitted: :any
      register Sinatra::Namespace
      helpers Legion::Logging::Helper
      helpers Legion::LLM::API::Namespaces::Helpers
      register Legion::LLM::API::Namespaces::OpenAI::Uploads
    end
  end

  before do
    allow(Legion::LLM).to receive(:started?).and_return(true)
    allow(Legion::LLM::API::Namespaces::OpenAI::Files).to receive(:files_dir).and_return(tmp_dir)
    Legion::LLM::API::Namespaces::OpenAI::Uploads::UPLOAD_STORE.clear
    Legion::LLM::API::Namespaces::OpenAI::Files::FILE_STORE.clear
  end

  after { FileUtils.rm_rf(tmp_dir) }

  describe 'POST /v1/uploads' do
    it 'creates a new upload object' do
      post '/v1/uploads',
           Legion::JSON.dump({ filename: 'training.jsonl', purpose: 'fine-tune', bytes: 1024 }),
           'CONTENT_TYPE' => 'application/json'

      expect(last_response.status).to eq(200)
      body = Legion::JSON.load(last_response.body)
      expect(body[:object]).to eq('upload')
      expect(body[:id]).to start_with('upload_')
      expect(body[:status]).to eq('pending')
      expect(body[:filename]).to eq('training.jsonl')
    end

    it 'requires filename, purpose, and bytes' do
      post '/v1/uploads',
           Legion::JSON.dump({ filename: 'x.jsonl' }),
           'CONTENT_TYPE' => 'application/json'
      expect(last_response.status).to eq(400)
    end
  end

  describe 'POST /v1/uploads/:id/cancel' do
    let(:upload_id) { 'upload_cancel001' }

    before do
      Legion::LLM::API::Namespaces::OpenAI::Uploads::UPLOAD_STORE[upload_id] = {
        id:         upload_id,
        filename:   'data.jsonl',
        purpose:    'batch',
        bytes:      100,
        created_at: Time.now,
        expires_at: Time.now + 3600,
        status:     'pending',
        parts:      [],
        file_id:    nil
      }
    end

    it 'cancels a pending upload' do
      post "/v1/uploads/#{upload_id}/cancel"
      expect(last_response.status).to eq(200)
      body = Legion::JSON.load(last_response.body)
      expect(body[:status]).to eq('cancelled')
    end

    it 'returns 404 for unknown upload' do
      post '/v1/uploads/upload_ghost/cancel'
      expect(last_response.status).to eq(404)
    end
  end

  describe 'POST /v1/uploads/:id/complete' do
    let(:upload_id) { 'upload_complete001' }
    let(:part_data) { 'hello world content' }

    before do
      Legion::LLM::API::Namespaces::OpenAI::Uploads::UPLOAD_STORE[upload_id] = {
        id:         upload_id,
        filename:   'assembled.txt',
        purpose:    'assistants',
        bytes:      part_data.bytesize,
        created_at: Time.now,
        expires_at: Time.now + 3600,
        status:     'pending',
        parts:      [{ id: 'part_001', data: part_data, created_at: Time.now }],
        file_id:    nil
      }
    end

    it 'assembles parts into a file and returns file object' do
      post "/v1/uploads/#{upload_id}/complete",
           Legion::JSON.dump({ part_ids: ['part_001'] }),
           'CONTENT_TYPE' => 'application/json'

      expect(last_response.status).to eq(200)
      body = Legion::JSON.load(last_response.body)
      expect(body[:object]).to eq('upload')
      expect(body[:status]).to eq('completed')
      expect(body[:file]).not_to be_nil
      expect(body[:file][:object]).to eq('file')
    end

    it 'returns 404 for unknown upload' do
      post '/v1/uploads/upload_nope/complete',
           Legion::JSON.dump({ part_ids: [] }),
           'CONTENT_TYPE' => 'application/json'
      expect(last_response.status).to eq(404)
    end

    it 'returns 400 for already-completed upload' do
      Legion::LLM::API::Namespaces::OpenAI::Uploads::UPLOAD_STORE[upload_id][:status] = 'completed'
      post "/v1/uploads/#{upload_id}/complete",
           Legion::JSON.dump({ part_ids: ['part_001'] }),
           'CONTENT_TYPE' => 'application/json'
      expect(last_response.status).to eq(400)
      body = Legion::JSON.load(last_response.body)
      expect(body[:error][:code]).to eq('upload_already_completed')
    end
  end
end
