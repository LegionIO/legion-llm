# frozen_string_literal: true

require 'spec_helper'
require 'rack/test'
require 'sinatra/base'
require 'sinatra/namespace'
require 'legion/llm/api/namespaces/helpers'

RSpec.describe 'Namespaces::OpenAI::Batches' do
  include Rack::Test::Methods

  before { require 'legion/llm/api/namespaces/openai/batches' }

  let(:app) do
    Class.new(Sinatra::Base) do
      set :host_authorization, permitted: :any
      register Sinatra::Namespace
      helpers Legion::Logging::Helper
      helpers Legion::LLM::API::Namespaces::Helpers
      register Legion::LLM::API::Namespaces::OpenAI::Batches
    end
  end

  before do
    allow(Legion::LLM).to receive(:started?).and_return(true)
    Legion::LLM::API::Namespaces::OpenAI::Batches::BATCH_STORE.clear
    stub_pool = instance_double(Concurrent::FixedThreadPool, post: nil)
    allow(Legion::LLM::API::Namespaces::OpenAI::Batches).to receive(:batch_pool).and_return(stub_pool)
  end

  describe 'POST /v1/batches' do
    let(:request_body) do
      {
        input_file_id:     'file-abc123',
        endpoint:          '/v1/chat/completions',
        completion_window: '24h'
      }
    end

    it 'creates a batch and returns batch object' do
      post '/v1/batches',
           Legion::JSON.dump(request_body),
           'CONTENT_TYPE' => 'application/json'

      expect(last_response.status).to eq(200)
      body = Legion::JSON.load(last_response.body)
      expect(body[:object]).to eq('batch')
      expect(body[:id]).to start_with('batch_')
      expect(body[:status]).to eq('validating')
      expect(body[:endpoint]).to eq('/v1/chat/completions')
    end

    it 'requires input_file_id field' do
      post '/v1/batches',
           Legion::JSON.dump(request_body.except(:input_file_id)),
           'CONTENT_TYPE' => 'application/json'

      expect(last_response.status).to eq(400)
      body = Legion::JSON.load(last_response.body)
      expect(body[:error][:code]).to eq('missing_fields')
    end

    it 'requires endpoint field' do
      post '/v1/batches',
           Legion::JSON.dump(request_body.except(:endpoint)),
           'CONTENT_TYPE' => 'application/json'

      expect(last_response.status).to eq(400)
    end
  end

  describe 'GET /v1/batches/:id' do
    let(:batch_id) { 'batch_test_001' }

    before do
      Legion::LLM::API::Namespaces::OpenAI::Batches::BATCH_STORE[batch_id] = {
        id:             batch_id,
        status:         :in_progress,
        endpoint:       '/v1/chat/completions',
        created_at:     Time.now,
        request_counts: { total: 5, completed: 2, failed: 0 },
        metadata:       {}
      }
    end

    it 'returns batch status' do
      get "/v1/batches/#{batch_id}"
      expect(last_response.status).to eq(200)
      body = Legion::JSON.load(last_response.body)
      expect(body[:object]).to eq('batch')
      expect(body[:id]).to eq(batch_id)
      expect(body[:status]).to eq('in_progress')
      expect(body[:request_counts][:total]).to eq(5)
    end

    it 'returns 404 for unknown batch' do
      get '/v1/batches/batch_does_not_exist'
      expect(last_response.status).to eq(404)
      body = Legion::JSON.load(last_response.body)
      expect(body[:error][:code]).to eq('batch_not_found')
    end
  end

  describe 'GET /v1/batches (list)' do
    before do
      3.times do |i|
        id = "batch_list_#{i}"
        Legion::LLM::API::Namespaces::OpenAI::Batches::BATCH_STORE[id] = {
          id:             id,
          status:         :completed,
          endpoint:       '/v1/chat/completions',
          created_at:     Time.now - (3 - i),
          request_counts: { total: 1, completed: 1, failed: 0 },
          metadata:       {}
        }
      end
    end

    it 'lists batches' do
      get '/v1/batches'
      expect(last_response.status).to eq(200)
      body = Legion::JSON.load(last_response.body)
      expect(body[:object]).to eq('list')
      expect(body[:data]).to be_an(Array)
      expect(body[:data].size).to eq(3)
    end

    it 'respects limit param' do
      get '/v1/batches?limit=2'
      body = Legion::JSON.load(last_response.body)
      expect(body[:data].size).to eq(2)
    end
  end

  describe 'POST /v1/batches/:id/cancel' do
    let(:batch_id) { 'batch_cancel_001' }

    before do
      Legion::LLM::API::Namespaces::OpenAI::Batches::BATCH_STORE[batch_id] = {
        id:             batch_id,
        status:         :in_progress,
        endpoint:       '/v1/chat/completions',
        created_at:     Time.now,
        request_counts: { total: 10, completed: 3, failed: 0 },
        metadata:       {}
      }
    end

    it 'cancels an in-progress batch' do
      post "/v1/batches/#{batch_id}/cancel"
      expect(last_response.status).to eq(200)
      body = Legion::JSON.load(last_response.body)
      expect(body[:status]).to eq('cancelling')
    end

    it 'returns 404 for unknown batch' do
      post '/v1/batches/batch_ghost/cancel'
      expect(last_response.status).to eq(404)
    end
  end
end
