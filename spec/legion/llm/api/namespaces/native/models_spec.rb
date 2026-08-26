# frozen_string_literal: true

require 'spec_helper'
require 'rack/test'
require 'sinatra/base'
require 'sinatra/namespace'

RSpec.describe 'Legion::LLM::API::Namespaces::Native::Models', :ssot_v3 do
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

  # D14: the models routes project the NEW Registry snapshot — publish a real
  # lane through the Phase 1 registry API instead of stubbing the deleted
  # Inventory.offerings read (the stub was inert: the route never read it).
  def activate_llama_lane
    activate(
      provider_family: 'ollama', instance_id: 'local',
      drafts: [offering_draft(model: 'llama3.2', tier: :local, supported: %i[chat])]
    )
  end

  before do
    allow(Legion::LLM).to receive(:started?).and_return(true)
  end

  describe 'GET /api/llm/models' do
    it 'returns 200 with models and offerings' do
      activate_llama_lane
      get '/api/llm/models'
      expect(last_response.status).to eq(200)
      result = Legion::JSON.load(last_response.body)
      expect(result[:data][:models]).to be_an(Array)
      expect(result[:data][:offerings]).to be_an(Array)
      expect(result[:data][:summary]).to be_a(Hash)
    end

    it 'includes legionio auto-routing model' do
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
      activate_llama_lane
      get '/api/llm/models/llama3.2'
      expect(last_response.status).to eq(200)
      result = Legion::JSON.load(last_response.body)
      expect(result[:data][:model][:id]).to eq('llama3.2')
    end

    it 'returns 200 for legionio auto-routing model' do
      get '/api/llm/models/legionio'
      expect(last_response.status).to eq(200)
      result = Legion::JSON.load(last_response.body)
      expect(result[:data][:model][:id]).to eq('legionio')
    end

    it 'returns 404 for unknown model' do
      get '/api/llm/models/nonexistent'
      expect(last_response.status).to eq(404)
      result = Legion::JSON.load(last_response.body)
      expect(result[:error][:code]).to eq('model_not_found')
    end
  end
end
