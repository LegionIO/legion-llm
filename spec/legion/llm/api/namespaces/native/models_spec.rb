# frozen_string_literal: true

require 'spec_helper'
require 'rack/test'
require 'sinatra/base'
require 'sinatra/namespace'

RSpec.describe 'Legion::LLM::API::Namespaces::Native::Models' do
  include Rack::Test::Methods

  before do
    require 'legion/llm/api/shared_helpers'
    require 'legion/llm/api/namespaces/helpers'
    require 'legion/llm/api/native/models'
    require 'legion/llm/api/namespaces/native/models'
  end

  let(:app) do
    Class.new(Sinatra::Base) do
      set :host_authorization, permitted: :any
      register Sinatra::Namespace
      helpers Legion::LLM::API::Namespaces::Helpers

      namespace '/api/llm/models' do
        register Legion::LLM::API::Namespaces::Native::Models
      end
    end
  end

  let(:sample_offering) do
    {
      offering_id:     'ollama:local:inference:llama3.2',
      model:           'llama3.2',
      type:            :inference,
      provider_family: 'ollama',
      instance_id:     'local',
      tier:            :local,
      capabilities:    ['chat'],
      limits:          { context_window: 128_000 },
      enabled:         true
    }
  end

  before do
    allow(Legion::LLM).to receive(:started?).and_return(true)
    allow(Legion::LLM::Inventory).to receive(:offerings).and_return([sample_offering])
  end

  describe 'GET /api/llm/models' do
    it 'returns 200 with models and offerings' do
      get '/api/llm/models'
      expect(last_response.status).to eq(200)
      result = Legion::JSON.load(last_response.body)
      expect(result[:data][:models]).to be_an(Array)
      expect(result[:data][:offerings]).to be_an(Array)
      expect(result[:data][:summary]).to be_a(Hash)
    end

    it 'includes legionio auto-routing model' do
      allow(Legion::LLM::Inventory).to receive(:offerings).and_return([])
      get '/api/llm/models'
      result = Legion::JSON.load(last_response.body)
      model_ids = result[:data][:models].map { |m| m[:id] }
      expect(model_ids).to include('legionio')
    end

    it 'returns 503 when LLM not started' do
      allow(Legion::LLM).to receive(:started?).and_return(false)
      get '/api/llm/models'
      expect(last_response.status).to eq(503)
    end
  end

  describe 'GET /api/llm/models/:id' do
    it 'returns 200 for known model' do
      allow(Legion::LLM::Inventory).to receive(:offerings).with(hash_including(model: 'llama3.2')).and_return([sample_offering])
      get '/api/llm/models/llama3.2'
      expect(last_response.status).to eq(200)
      result = Legion::JSON.load(last_response.body)
      expect(result[:data][:model][:id]).to eq('llama3.2')
    end

    it 'returns 200 for legionio auto-routing model' do
      allow(Legion::LLM::Inventory).to receive(:offerings).with(hash_including(model: 'legionio')).and_return([])
      get '/api/llm/models/legionio'
      expect(last_response.status).to eq(200)
      result = Legion::JSON.load(last_response.body)
      expect(result[:data][:model][:id]).to eq('legionio')
    end

    it 'returns 404 for unknown model' do
      allow(Legion::LLM::Inventory).to receive(:offerings).with(hash_including(model: 'nonexistent')).and_return([])
      get '/api/llm/models/nonexistent'
      expect(last_response.status).to eq(404)
      result = Legion::JSON.load(last_response.body)
      expect(result[:error][:code]).to eq('model_not_found')
    end
  end
end
