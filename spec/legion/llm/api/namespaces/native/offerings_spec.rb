# frozen_string_literal: true

require 'spec_helper'
require 'rack/test'
require 'sinatra/base'
require 'sinatra/namespace'

RSpec.describe 'Legion::LLM::API::Namespaces::Native::Offerings' do
  include Rack::Test::Methods

  before do
    require 'legion/llm/api/shared_helpers'
    require 'legion/llm/api/namespaces/helpers'
    require 'legion/llm/api/native/offerings'
    require 'legion/llm/api/namespaces/native/offerings'
  end

  let(:app) do
    Class.new(Sinatra::Base) do
      set :host_authorization, permitted: :any
      register Sinatra::Namespace
      helpers Legion::LLM::API::Namespaces::Helpers

      namespace '/api/llm/offerings' do
        register Legion::LLM::API::Namespaces::Native::Offerings
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
      limits:          {},
      enabled:         true,
      cost:            {},
      health:          {}
    }
  end

  before do
    allow(Legion::LLM).to receive(:started?).and_return(true)
    allow(Legion::LLM::Inventory).to receive(:offerings).and_return([sample_offering])
  end

  describe 'GET /api/llm/offerings' do
    it 'returns 200 with grouped offerings' do
      get '/api/llm/offerings'
      expect(last_response.status).to eq(200)
      result = Legion::JSON.load(last_response.body)
      expect(result[:data][:offerings]).to be_a(Hash)
      expect(result[:data][:summary][:total]).to eq(1)
    end

    it 'groups by tier > provider > instance' do
      get '/api/llm/offerings'
      result = Legion::JSON.load(last_response.body)
      expect(result[:data][:offerings][:local]).to be_a(Hash)
    end

    it 'returns 503 when LLM not started' do
      allow(Legion::LLM).to receive(:started?).and_return(false)
      get '/api/llm/offerings'
      expect(last_response.status).to eq(503)
    end
  end

  describe 'GET /api/llm/offerings/:id' do
    it 'returns 200 for known offering' do
      allow(Legion::LLM::Inventory).to receive(:offerings).with(hash_including(offering_id: 'ollama:local:inference:llama3.2')).and_return([sample_offering])
      get '/api/llm/offerings/ollama:local:inference:llama3.2'
      expect(last_response.status).to eq(200)
      result = Legion::JSON.load(last_response.body)
      expect(result[:data][:offering]).to be_a(Hash)
    end

    it 'returns 404 for unknown offering' do
      allow(Legion::LLM::Inventory).to receive(:offerings).with(hash_including(offering_id: 'bad:id')).and_return([])
      get '/api/llm/offerings/bad:id'
      expect(last_response.status).to eq(404)
      result = Legion::JSON.load(last_response.body)
      expect(result[:error][:code]).to eq('offering_not_found')
    end
  end
end
