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

  # D14: offerings are projected from the NEW Registry snapshot — publish a
  # real instance through the Phase 1 registry API instead of stubbing the
  # (no longer read) legacy lane store.
  before do
    allow(Legion::LLM).to receive(:started?).and_return(true)
    SsotV3SnapshotFactory.activate(
      provider_family: :ollama,
      instance_id:     'local',
      drafts:          [
        SsotV3SnapshotFactory.offering_draft(model: 'llama3.2', tier: :local, supported: %i[chat stream_chat])
      ]
    )
  end

  def activated_offering_id
    key = SsotV3SnapshotFactory.instance_key(provider_family: :ollama, instance_id: 'local')
    SsotV3SnapshotFactory.snapshot.offerings_for(instance_key: key).first.offering_id
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
      offering = result[:data][:offerings][:local][:ollama][:local].first
      expect(offering[:model]).to eq('llama3.2')
      expect(offering[:health]).to include(available: true, circuit_state: 'closed')
    end

    it 'returns 503 when LLM not started' do
      allow(Legion::LLM).to receive(:started?).and_return(false)
      get '/api/llm/offerings'
      expect(last_response.status).to eq(503)
    end
  end

  describe 'GET /api/llm/offerings/:id' do
    it 'returns 200 for known offering' do
      get "/api/llm/offerings/#{activated_offering_id}"
      expect(last_response.status).to eq(200)
      result = Legion::JSON.load(last_response.body)
      expect(result[:data][:offering]).to be_a(Hash)
      expect(result[:data][:offering][:model]).to eq('llama3.2')
    end

    it 'returns 404 for unknown offering' do
      get '/api/llm/offerings/bad:id'
      expect(last_response.status).to eq(404)
      result = Legion::JSON.load(last_response.body)
      expect(result[:error][:code]).to eq('offering_not_found')
    end
  end
end
