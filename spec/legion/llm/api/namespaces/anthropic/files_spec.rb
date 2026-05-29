# frozen_string_literal: true

require 'spec_helper'
require 'rack/test'
require 'sinatra/base'
require 'sinatra/namespace'
require 'legion/llm/api/namespaces/helpers'
require 'legion/llm/api/namespaces/anthropic/files'

RSpec.describe 'Namespaces::Anthropic::Files' do
  include Rack::Test::Methods

  let(:app) do
    Class.new(Sinatra::Base) do
      set :host_authorization, permitted: :any
      register Sinatra::Namespace
      helpers Legion::LLM::API::Namespaces::Helpers

      namespace('/v1/files') { register Legion::LLM::API::Namespaces::Anthropic::Files }
    end
  end

  before do
    allow(Legion::LLM).to receive(:started?).and_return(true)
  end

  # ─── POST /v1/files ───────────────────────────────────────────────

  describe 'POST /v1/files (upload)' do
    let(:file_content) do
      %({"custom_id":"req-1","params":{"model":"claude-sonnet-4-6","max_tokens":100,"messages":[{"role":"user","content":"Hi"}]}}\n)
    end

    context 'with valid multipart upload' do
      it 'returns 200 with file object' do
        post '/v1/files',
             { file: Rack::Test::UploadedFile.new(StringIO.new(file_content), 'application/x-jsonl', original_filename: 'input.jsonl'), purpose: 'batch_input' }

        expect(last_response.status).to eq(200)
        result = Legion::JSON.load(last_response.body)
        expect(result[:type]).to eq('file')
        expect(result[:id]).to start_with('file_')
        expect(result[:filename]).to eq('input.jsonl')
        expect(result[:purpose]).to eq('batch_input')
        expect(result[:size]).to eq(file_content.bytesize)
        expect(result[:created_at]).to be_a(String)
        expect(result[:mime_type]).to be_a(String)
      end

      it 'stores the file so it can be retrieved' do
        post '/v1/files',
             { file: Rack::Test::UploadedFile.new(StringIO.new(file_content), 'application/x-jsonl', original_filename: 'input.jsonl'), purpose: 'batch_input' }

        file_id = Legion::JSON.load(last_response.body)[:id]

        get "/v1/files/#{file_id}"
        expect(last_response.status).to eq(200)
        meta = Legion::JSON.load(last_response.body)
        expect(meta[:id]).to eq(file_id)
      end
    end

    context 'missing file field' do
      it 'returns 400 Anthropic error' do
        post '/v1/files', { purpose: 'batch_input' }
        expect(last_response.status).to eq(400)
        result = Legion::JSON.load(last_response.body)
        expect(result[:type]).to eq('error')
        expect(result[:error][:type]).to eq('invalid_request_error')
        expect(result[:error][:message]).to include('file')
      end
    end

    context 'missing purpose field' do
      it 'returns 400 Anthropic error' do
        post '/v1/files',
             { file: Rack::Test::UploadedFile.new(StringIO.new(file_content), 'application/x-jsonl', original_filename: 'input.jsonl') }
        expect(last_response.status).to eq(400)
        result = Legion::JSON.load(last_response.body)
        expect(result[:type]).to eq('error')
        expect(result[:error][:type]).to eq('invalid_request_error')
        expect(result[:error][:message]).to include('purpose')
      end
    end

    context 'with plain text content type' do
      it 'infers mime_type from upload content type' do
        post '/v1/files',
             { file: Rack::Test::UploadedFile.new(StringIO.new('hello world'), 'text/plain', original_filename: 'notes.txt'), purpose: 'assistants' }
        expect(last_response.status).to eq(200)
        result = Legion::JSON.load(last_response.body)
        expect(result[:mime_type]).to eq('text/plain')
        expect(result[:filename]).to eq('notes.txt')
      end
    end
  end

  # ─── GET /v1/files ────────────────────────────────────────────────

  describe 'GET /v1/files (list)' do
    before do
      content_a = 'file A content'
      content_b = 'file B content'
      post '/v1/files', { file: Rack::Test::UploadedFile.new(StringIO.new(content_a), 'text/plain', original_filename: 'a.txt'), purpose: 'batch_input' }
      post '/v1/files', { file: Rack::Test::UploadedFile.new(StringIO.new(content_b), 'text/plain', original_filename: 'b.txt'), purpose: 'assistants' }
    end

    it 'returns paginated list format' do
      get '/v1/files'
      expect(last_response.status).to eq(200)
      result = Legion::JSON.load(last_response.body)
      expect(result[:data]).to be_an(Array)
      expect(result).to have_key(:has_more)
      expect(result).to have_key(:first_id)
      expect(result).to have_key(:last_id)
    end

    it 'includes uploaded files in list' do
      get '/v1/files'
      result = Legion::JSON.load(last_response.body)
      filenames = result[:data].map { |f| f[:filename] }
      expect(filenames).to include('a.txt', 'b.txt')
    end

    it 'respects limit param' do
      get '/v1/files?limit=1'
      result = Legion::JSON.load(last_response.body)
      expect(result[:data].size).to eq(1)
    end

    it 'each entry has required file object fields' do
      get '/v1/files'
      result = Legion::JSON.load(last_response.body)
      entry = result[:data].first
      expect(entry[:type]).to eq('file')
      expect(entry[:id]).to start_with('file_')
      expect(entry[:filename]).to be_a(String)
      expect(entry[:purpose]).to be_a(String)
      expect(entry[:size]).to be_a(Integer)
      expect(entry[:created_at]).to be_a(String)
      expect(entry[:mime_type]).to be_a(String)
    end

    context 'with purpose filter' do
      it 'filters files by purpose' do
        get '/v1/files?purpose=batch_input'
        result = Legion::JSON.load(last_response.body)
        purposes = result[:data].map { |f| f[:purpose] }.uniq
        expect(purposes).to eq(['batch_input'])
      end
    end
  end

  # ─── GET /v1/files/:id ────────────────────────────────────────────

  describe 'GET /v1/files/:id (metadata)' do
    let(:file_id) do
      post '/v1/files',
           { file: Rack::Test::UploadedFile.new(StringIO.new('hello'), 'text/plain', original_filename: 'test.txt'), purpose: 'batch_input' }
      Legion::JSON.load(last_response.body)[:id]
    end

    it 'returns file metadata' do
      get "/v1/files/#{file_id}"
      expect(last_response.status).to eq(200)
      result = Legion::JSON.load(last_response.body)
      expect(result[:id]).to eq(file_id)
      expect(result[:type]).to eq('file')
      expect(result[:filename]).to eq('test.txt')
      expect(result[:purpose]).to eq('batch_input')
      expect(result[:size]).to eq(5)
    end

    it 'returns 404 for unknown id' do
      get '/v1/files/file_nonexistent_9999'
      expect(last_response.status).to eq(404)
      result = Legion::JSON.load(last_response.body)
      expect(result[:type]).to eq('error')
      expect(result[:error][:type]).to eq('not_found_error')
    end
  end

  # ─── GET /v1/files/:id/content ────────────────────────────────────

  describe 'GET /v1/files/:id/content (download)' do
    let(:original_content) { "line1\nline2\nline3\n" }
    let(:file_id) do
      post '/v1/files',
           { file: Rack::Test::UploadedFile.new(StringIO.new(original_content), 'text/plain', original_filename: 'data.txt'), purpose: 'batch_input' }
      Legion::JSON.load(last_response.body)[:id]
    end

    it 'returns raw file bytes' do
      get "/v1/files/#{file_id}/content"
      expect(last_response.status).to eq(200)
      expect(last_response.body).to eq(original_content)
    end

    it 'sets Content-Type from stored mime_type' do
      get "/v1/files/#{file_id}/content"
      expect(last_response.content_type).to include('text/plain')
    end

    it 'sets Content-Disposition with filename' do
      get "/v1/files/#{file_id}/content"
      expect(last_response.headers['Content-Disposition']).to include('data.txt')
    end

    it 'returns 404 for unknown id' do
      get '/v1/files/file_nonexistent_9999/content'
      expect(last_response.status).to eq(404)
      result = Legion::JSON.load(last_response.body)
      expect(result[:type]).to eq('error')
      expect(result[:error][:type]).to eq('not_found_error')
    end
  end

  # ─── DELETE /v1/files/:id ─────────────────────────────────────────

  describe 'DELETE /v1/files/:id' do
    let(:file_id) do
      post '/v1/files',
           { file: Rack::Test::UploadedFile.new(StringIO.new('bye'), 'text/plain', original_filename: 'bye.txt'), purpose: 'batch_input' }
      Legion::JSON.load(last_response.body)[:id]
    end

    it 'returns delete confirmation object' do
      delete "/v1/files/#{file_id}"
      expect(last_response.status).to eq(200)
      result = Legion::JSON.load(last_response.body)
      expect(result[:id]).to eq(file_id)
      expect(result[:type]).to eq('file')
      expect(result[:deleted]).to be true
    end

    it 'file is no longer accessible after delete' do
      delete "/v1/files/#{file_id}"
      get "/v1/files/#{file_id}"
      expect(last_response.status).to eq(404)
    end

    it 'returns 404 for unknown id' do
      delete '/v1/files/file_nonexistent_9999'
      expect(last_response.status).to eq(404)
      result = Legion::JSON.load(last_response.body)
      expect(result[:type]).to eq('error')
      expect(result[:error][:type]).to eq('not_found_error')
    end
  end
end
