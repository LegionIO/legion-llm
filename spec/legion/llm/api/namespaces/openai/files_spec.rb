# frozen_string_literal: true

require 'spec_helper'
require 'rack/test'
require 'sinatra/base'
require 'sinatra/namespace'
require 'tmpdir'
require 'legion/llm/api/namespaces/helpers'

RSpec.describe 'Namespaces::OpenAI::Files' do
  include Rack::Test::Methods

  let(:tmp_dir) { Dir.mktmpdir }

  before { require 'legion/llm/api/namespaces/openai/files' }

  let(:app) do
    Class.new(Sinatra::Base) do
      set :host_authorization, permitted: :any
      register Sinatra::Namespace
      helpers Legion::Logging::Helper
      helpers Legion::LLM::API::Namespaces::Helpers
      register Legion::LLM::API::Namespaces::OpenAI::Files
    end
  end

  before do
    allow(Legion::LLM).to receive(:started?).and_return(true)
    allow(Legion::LLM::API::Namespaces::OpenAI::Files).to receive(:files_dir).and_return(tmp_dir)
    Legion::LLM::API::Namespaces::OpenAI::Files::FILE_STORE.clear
  end

  after { FileUtils.rm_rf(tmp_dir) }

  describe 'POST /v1/files (multipart upload)' do
    let(:upload_file) do
      path = ::File.join(tmp_dir, 'upload.txt')
      ::File.write(path, 'test content')
      Rack::Test::UploadedFile.new(path, 'text/plain')
    end

    it 'uploads a file and returns file object' do
      post '/v1/files', { file: upload_file, purpose: 'assistants' }

      expect(last_response.status).to eq(200)
      body = Legion::JSON.load(last_response.body)
      expect(body[:object]).to eq('file')
      expect(body[:id]).to start_with('file-')
      expect(body[:purpose]).to eq('assistants')
      expect(body[:bytes]).to be > 0
    end

    it 'requires file param' do
      post '/v1/files', { purpose: 'assistants' }
      expect(last_response.status).to eq(400)
      body = Legion::JSON.load(last_response.body)
      expect(body[:error][:type]).to eq('invalid_request_error')
    end

    it 'requires purpose param' do
      post '/v1/files', { file: upload_file }
      expect(last_response.status).to eq(400)
    end
  end

  describe 'GET /v1/files (list)' do
    before do
      2.times do |i|
        Legion::LLM::API::Namespaces::OpenAI::Files::FILE_STORE["file-#{i}"] = {
          id: "file-#{i}", filename: "test#{i}.txt", purpose: 'assistants',
          bytes: 100, created_at: Time.now, status: 'uploaded'
        }
      end
    end

    it 'returns list of files' do
      get '/v1/files'
      expect(last_response.status).to eq(200)
      body = Legion::JSON.load(last_response.body)
      expect(body[:object]).to eq('list')
      expect(body[:data].size).to eq(2)
    end

    it 'filters by purpose' do
      Legion::LLM::API::Namespaces::OpenAI::Files::FILE_STORE['file-fine-tune'] = {
        id: 'file-fine-tune', filename: 'ft.jsonl', purpose: 'fine-tune',
        bytes: 500, created_at: Time.now, status: 'uploaded'
      }
      get '/v1/files?purpose=fine-tune'
      body = Legion::JSON.load(last_response.body)
      expect(body[:data].size).to eq(1)
      expect(body[:data].first[:purpose]).to eq('fine-tune')
    end
  end

  describe 'GET /v1/files/:id' do
    let(:file_id) { 'file-getme' }

    before do
      Legion::LLM::API::Namespaces::OpenAI::Files::FILE_STORE[file_id] = {
        id: file_id, filename: 'test.txt', purpose: 'assistants',
        bytes: 42, created_at: Time.now, status: 'uploaded'
      }
    end

    it 'returns file metadata' do
      get "/v1/files/#{file_id}"
      expect(last_response.status).to eq(200)
      body = Legion::JSON.load(last_response.body)
      expect(body[:object]).to eq('file')
      expect(body[:id]).to eq(file_id)
    end

    it 'returns 404 for unknown file' do
      get '/v1/files/file-does-not-exist'
      expect(last_response.status).to eq(404)
      body = Legion::JSON.load(last_response.body)
      expect(body[:error][:code]).to eq('file_not_found')
    end
  end

  describe 'DELETE /v1/files/:id' do
    let(:file_id) { 'file-deleteme' }

    before do
      Legion::LLM::API::Namespaces::OpenAI::Files::FILE_STORE[file_id] = {
        id: file_id, filename: 'rm.txt', purpose: 'assistants',
        bytes: 10, created_at: Time.now, status: 'uploaded'
      }
      ::File.write(::File.join(tmp_dir, file_id), 'content')
    end

    it 'deletes the file' do
      delete "/v1/files/#{file_id}"
      expect(last_response.status).to eq(200)
      body = Legion::JSON.load(last_response.body)
      expect(body[:deleted]).to be true
      expect(Legion::LLM::API::Namespaces::OpenAI::Files::FILE_STORE[file_id]).to be_nil
    end

    it 'returns 404 for unknown file' do
      delete '/v1/files/file-nope'
      expect(last_response.status).to eq(404)
    end
  end

  describe 'GET /v1/files/:id/content' do
    let(:file_id) { 'file-content' }
    let(:content) { "line1\nline2\nline3\n" }

    before do
      Legion::LLM::API::Namespaces::OpenAI::Files::FILE_STORE[file_id] = {
        id: file_id, filename: 'data.jsonl', purpose: 'batch',
        bytes: content.bytesize, created_at: Time.now, status: 'uploaded'
      }
      ::File.write(::File.join(tmp_dir, file_id), content)
    end

    it 'returns raw file bytes' do
      get "/v1/files/#{file_id}/content"
      expect(last_response.status).to eq(200)
      expect(last_response.body).to eq(content)
    end

    it 'returns 404 when file data missing from disk' do
      ::File.delete(::File.join(tmp_dir, file_id))
      get "/v1/files/#{file_id}/content"
      expect(last_response.status).to eq(404)
    end
  end
end
