# frozen_string_literal: true

require 'spec_helper'
require 'rack/test'
require 'sinatra/base'
require 'legion/llm/api/namespaces/registration'
require 'legion/llm/api/namespaces/anthropic/files'

RSpec.describe 'Anthropic Files Integration' do
  include Rack::Test::Methods

  let(:app) do
    Legion::LLM::API::Namespaces::Anthropic::Files.reset_metadata_store!
    klass = Class.new(Sinatra::Base) do
      set :host_authorization, permitted: :any
    end
    Legion::LLM::API::Namespaces::Registration.registered(klass)
    klass
  end

  before do
    allow(Legion::LLM).to receive(:started?).and_return(true)
  end

  let(:anthropic_headers) do
    {
      'HTTP_X_API_KEY'         => 'legion',
      'HTTP_ANTHROPIC_VERSION' => '2023-06-01'
    }
  end

  describe 'full upload → list → download → delete lifecycle' do
    it 'completes without errors' do
      # 1. Upload
      post '/v1/files',
           { file: Rack::Test::UploadedFile.new(StringIO.new('batch line'), 'application/x-jsonl', original_filename: 'batch.jsonl'), purpose: 'batch_input' },
           anthropic_headers
      expect(last_response.status).to eq(200)
      file_id = Legion::JSON.load(last_response.body)[:id]
      expect(file_id).to start_with('file_')

      # 2. List
      get '/v1/files', {}, anthropic_headers
      expect(last_response.status).to eq(200)
      ids = Legion::JSON.load(last_response.body)[:data].map { |f| f[:id] }
      expect(ids).to include(file_id)

      # 3. Metadata
      get "/v1/files/#{file_id}", {}, anthropic_headers
      expect(last_response.status).to eq(200)
      expect(Legion::JSON.load(last_response.body)[:filename]).to eq('batch.jsonl')

      # 4. Content
      get "/v1/files/#{file_id}/content", {}, anthropic_headers
      expect(last_response.status).to eq(200)
      expect(last_response.body).to eq('batch line')

      # 5. Delete
      delete "/v1/files/#{file_id}", {}, anthropic_headers
      expect(last_response.status).to eq(200)
      expect(Legion::JSON.load(last_response.body)[:deleted]).to be true

      # 6. Verify gone
      get "/v1/files/#{file_id}", {}, anthropic_headers
      expect(last_response.status).to eq(404)
    end
  end

  describe 'error cases via registered app' do
    it 'returns 400 when file field is missing' do
      post '/v1/files', { purpose: 'batch_input' }, anthropic_headers
      expect(last_response.status).to eq(400)
      result = Legion::JSON.load(last_response.body)
      expect(result[:type]).to eq('error')
      expect(result[:error][:type]).to eq('invalid_request_error')
    end

    it 'returns 404 for nonexistent file metadata' do
      get '/v1/files/file_does_not_exist_here', {}, anthropic_headers
      expect(last_response.status).to eq(404)
    end

    it 'returns 404 for nonexistent file content' do
      get '/v1/files/file_does_not_exist_here/content', {}, anthropic_headers
      expect(last_response.status).to eq(404)
    end
  end
end
