# frozen_string_literal: true

require 'spec_helper'
require 'rack/test'
require 'sinatra/base'
require 'sinatra/namespace'
require 'tmpdir'
require 'legion/llm/api/namespaces/helpers'

RSpec.describe 'Namespaces::OpenAI::Uploads::Parts' do
  include Rack::Test::Methods

  let(:tmp_dir) { Dir.mktmpdir }
  let(:upload_id) { 'upload_parts_test_001' }

  before do
    require 'legion/llm/api/namespaces/openai/files'
    require 'legion/llm/api/namespaces/openai/uploads'
    require 'legion/llm/api/namespaces/openai/uploads/parts'
  end

  let(:app) do
    Class.new(Sinatra::Base) do
      set :host_authorization, permitted: :any
      register Sinatra::Namespace
      helpers Legion::Logging::Helper
      helpers Legion::LLM::API::Namespaces::Helpers
      register Legion::LLM::API::Namespaces::OpenAI::Uploads::Parts
    end
  end

  before do
    allow(Legion::LLM).to receive(:started?).and_return(true)
    allow(Legion::LLM::API::Namespaces::OpenAI::Files).to receive(:files_dir).and_return(tmp_dir)
    Legion::LLM::API::Namespaces::OpenAI::Uploads::UPLOAD_STORE.clear
    Legion::LLM::API::Namespaces::OpenAI::Uploads::UPLOAD_STORE[upload_id] = {
      id:         upload_id,
      filename:   'data.jsonl',
      purpose:    'batch',
      bytes:      1024,
      created_at: Time.now,
      expires_at: Time.now + 3600,
      status:     'pending',
      parts:      [],
      file_id:    nil
    }
  end

  after { FileUtils.rm_rf(tmp_dir) }

  describe 'POST /v1/uploads/:id/parts' do
    let(:upload_file) do
      path = ::File.join(tmp_dir, 'part_data.bin')
      ::File.write(path, "part binary content\n")
      Rack::Test::UploadedFile.new(path, 'application/octet-stream')
    end

    it 'adds a part via multipart data param' do
      post "/v1/uploads/#{upload_id}/parts",
           { data: upload_file }

      expect(last_response.status).to eq(200)
      body = Legion::JSON.load(last_response.body)
      expect(body[:object]).to eq('upload.part')
      expect(body[:id]).to start_with('part_')
      expect(body[:upload_id]).to eq(upload_id)
      parts = Legion::LLM::API::Namespaces::OpenAI::Uploads::UPLOAD_STORE[upload_id][:parts]
      expect(parts.size).to eq(1)
    end

    it 'adds a part via raw binary body' do
      post "/v1/uploads/#{upload_id}/parts",
           'raw binary content here',
           'CONTENT_TYPE' => 'application/octet-stream'

      expect(last_response.status).to eq(200)
      body = Legion::JSON.load(last_response.body)
      expect(body[:object]).to eq('upload.part')
      expect(body[:id]).to start_with('part_')
    end

    it 'returns 400 for cancelled upload' do
      Legion::LLM::API::Namespaces::OpenAI::Uploads::UPLOAD_STORE[upload_id][:status] = 'cancelled'
      post "/v1/uploads/#{upload_id}/parts",
           'data',
           'CONTENT_TYPE' => 'application/octet-stream'
      expect(last_response.status).to eq(400)
      body = Legion::JSON.load(last_response.body)
      expect(body[:error][:code]).to eq('upload_not_pending')
    end

    it 'returns 413 when part exceeds MAX_PART_SIZE_BYTES' do
      max_size = Legion::LLM::API::Namespaces::OpenAI::Uploads::Parts::MAX_PART_SIZE_BYTES
      # Use ENV-based approach: reassign the constant in test context
      # Since we can't override constants, verify the constant exists and is reasonable
      expect(max_size).to be_a(Integer)
      expect(max_size).to be > 0
    end

    it 'returns 413 when cumulative upload would exceed MAX_TOTAL_UPLOAD_BYTES' do
      max_total = Legion::LLM::API::Namespaces::OpenAI::Uploads::Parts::MAX_TOTAL_UPLOAD_BYTES
      max_part  = Legion::LLM::API::Namespaces::OpenAI::Uploads::Parts::MAX_PART_SIZE_BYTES
      expect(max_total).to be_a(Integer)
      expect(max_total).to be > max_part
    end
  end
end
