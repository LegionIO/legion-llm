# frozen_string_literal: true

require 'spec_helper'
require 'rack/test'
require 'sinatra/base'
require 'sinatra/namespace'

RSpec.describe 'Legion::LLM::API::Namespaces::Native::Providers' do
  include Rack::Test::Methods

  before do
    require 'legion/llm/api/shared_helpers'
    require 'legion/llm/api/namespaces/helpers'
    require 'legion/llm/api/native/providers'
    require 'legion/llm/api/namespaces/native/providers'
  end

  let(:app) do
    Class.new(Sinatra::Base) do
      set :host_authorization, permitted: :any
      register Sinatra::Namespace
      helpers Legion::LLM::API::Namespaces::Helpers

      namespace '/api/llm/providers' do
        register Legion::LLM::API::Namespaces::Native::Providers
      end
    end
  end

  let(:registry_instances) do
    [
      {
        provider:  :ollama,
        instance:  :local,
        metadata:  {
          tier:         :local,
          capabilities: [:chat],
          source:       'ollama_discovery'
        }
      }
    ]
  end

  before do
    allow(Legion::LLM).to receive(:started?).and_return(true)
    allow(Legion::LLM::Call::Registry).to receive(:all_instances).and_return(registry_instances)
    allow(Legion::LLM::Router).to receive(:routing_enabled?).and_return(false)
    allow(Legion::LLM::Router).to receive(:health_tracker).and_return(nil)
  end

  describe 'GET /api/llm/providers' do
    it 'returns 200 with provider list' do
      get '/api/llm/providers'
      expect(last_response.status).to eq(200)
      result = Legion::JSON.load(last_response.body)
      expect(result[:data][:providers]).to be_an(Array)
      expect(result[:data][:summary][:total]).to eq(1)
    end

    it 'includes routing_enabled in summary' do
      get '/api/llm/providers'
      result = Legion::JSON.load(last_response.body)
      expect(result[:data][:summary][:routing_enabled]).to eq(false)
    end

    it 'returns 503 when LLM not started' do
      allow(Legion::LLM).to receive(:started?).and_return(false)
      get '/api/llm/providers'
      expect(last_response.status).to eq(503)
    end

    it 'returns empty list when registry raises' do
      allow(Legion::LLM::Call::Registry).to receive(:all_instances).and_raise(StandardError, 'registry down')
      get '/api/llm/providers'
      expect(last_response.status).to eq(200)
      result = Legion::JSON.load(last_response.body)
      expect(result[:data][:providers]).to eq([])
    end
  end

  describe 'GET /api/llm/providers/:name' do
    it 'returns 200 with matching provider instances' do
      get '/api/llm/providers/ollama'
      expect(last_response.status).to eq(200)
      result = Legion::JSON.load(last_response.body)
      expect(result[:data][:provider]).to eq('ollama')
      expect(result[:data][:instances]).to be_an(Array)
      expect(result[:data][:instances].size).to eq(1)
    end

    it 'returns 404 for unknown provider' do
      get '/api/llm/providers/unknown_provider'
      expect(last_response.status).to eq(404)
      result = Legion::JSON.load(last_response.body)
      expect(result[:error][:code]).to eq('provider_not_found')
    end
  end
end
