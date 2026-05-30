# frozen_string_literal: true

require 'spec_helper'
require 'rack/test'
require 'sinatra/base'
require 'sinatra/namespace'

RSpec.describe 'Legion::LLM::API::Namespaces::Native::Tiers' do
  include Rack::Test::Methods

  before do
    require 'legion/llm/api/shared_helpers'
    require 'legion/llm/api/namespaces/helpers'
    require 'legion/llm/api/native/tiers'
    require 'legion/llm/api/namespaces/native/tiers'
  end

  let(:app) do
    Class.new(Sinatra::Base) do
      set :host_authorization, permitted: :any
      register Sinatra::Namespace
      helpers Legion::LLM::API::Namespaces::Helpers

      namespace '/api/llm/tiers' do
        register Legion::LLM::API::Namespaces::Native::Tiers
      end
    end
  end

  let(:tiers_tree) do
    {
      'local'    => {
        available: true,
        providers: {
          'ollama' => {
            instances: {
              'local' => {
                health:       'closed',
                capabilities: ['chat'],
                models:       [{ id: 'llama3.2', type: 'inference', capabilities: ['chat'], limits: {}, enabled: true }]
              }
            }
          }
        }
      },
      'frontier' => {
        available: false,
        providers: {}
      }
    }
  end

  before do
    allow(Legion::LLM).to receive(:started?).and_return(true)
    allow(Legion::LLM::API::Native::Tiers).to receive(:build_tiers_tree).and_return(tiers_tree)
    allow(Legion::LLM::API::Native::Tiers).to receive(:tier_priority).and_return(%w[local fleet frontier])
    allow(Legion::LLM::API::Native::Tiers).to receive(:privacy_mode?).and_return(false)
    Legion::LLM::API::Namespaces::Native::Tiers.reset_cache!
  end

  describe 'GET /api/llm/tiers' do
    it 'returns 200 with full tier tree' do
      get '/api/llm/tiers'
      expect(last_response.status).to eq(200)
      result = Legion::JSON.load(last_response.body)
      expect(result[:data][:tiers]).to be_a(Hash)
      expect(result[:data][:priority]).to be_an(Array)
      expect(result[:data][:privacy_mode]).to eq(false)
    end

    it 'returns 503 when LLM not started' do
      allow(Legion::LLM).to receive(:started?).and_return(false)
      get '/api/llm/tiers'
      expect(last_response.status).to eq(503)
    end
  end

  describe 'GET /api/llm/tiers/:tier' do
    it 'returns 200 for known tier' do
      get '/api/llm/tiers/local'
      expect(last_response.status).to eq(200)
      result = Legion::JSON.load(last_response.body)
      expect(result[:data][:tier]).to eq('local')
      expect(result[:data][:available]).to eq(true)
    end

    it 'returns 404 for unknown tier' do
      get '/api/llm/tiers/nonexistent'
      expect(last_response.status).to eq(404)
      result = Legion::JSON.load(last_response.body)
      expect(result[:error][:code]).to eq('tier_not_found')
    end
  end

  describe 'GET /api/llm/tiers/:tier/providers' do
    it 'returns 200 with providers for known tier' do
      get '/api/llm/tiers/local/providers'
      expect(last_response.status).to eq(200)
      result = Legion::JSON.load(last_response.body)
      expect(result[:data][:providers]).to be_a(Hash)
    end

    it 'returns 404 for unknown tier' do
      get '/api/llm/tiers/nonexistent/providers'
      expect(last_response.status).to eq(404)
    end
  end

  describe 'GET /api/llm/tiers/:tier/providers/:provider' do
    it 'returns 200 for known tier+provider' do
      get '/api/llm/tiers/local/providers/ollama'
      expect(last_response.status).to eq(200)
      result = Legion::JSON.load(last_response.body)
      expect(result[:data][:provider]).to eq('ollama')
    end

    it 'returns 404 for unknown provider in known tier' do
      get '/api/llm/tiers/local/providers/unknown_provider'
      expect(last_response.status).to eq(404)
      result = Legion::JSON.load(last_response.body)
      expect(result[:error][:code]).to eq('provider_not_found')
    end
  end

  describe 'GET /api/llm/tiers/:tier/providers/:provider/models' do
    it 'returns 200 with deduplicated models across instances' do
      get '/api/llm/tiers/local/providers/ollama/models'
      expect(last_response.status).to eq(200)
      result = Legion::JSON.load(last_response.body)
      expect(result[:data][:models]).to be_an(Array)
    end
  end

  describe 'GET /api/llm/tiers/:tier/providers/:provider/instances' do
    it 'returns 200 with instances hash' do
      get '/api/llm/tiers/local/providers/ollama/instances'
      expect(last_response.status).to eq(200)
      result = Legion::JSON.load(last_response.body)
      expect(result[:data][:instances]).to be_a(Hash)
    end
  end

  describe 'GET /api/llm/tiers/:tier/providers/:provider/instances/:instance' do
    it 'returns 200 for known instance' do
      get '/api/llm/tiers/local/providers/ollama/instances/local'
      expect(last_response.status).to eq(200)
      result = Legion::JSON.load(last_response.body)
      expect(result[:data][:instance]).to eq('local')
    end

    it 'returns 404 for unknown instance' do
      get '/api/llm/tiers/local/providers/ollama/instances/unknown'
      expect(last_response.status).to eq(404)
      result = Legion::JSON.load(last_response.body)
      expect(result[:error][:code]).to eq('instance_not_found')
    end
  end

  describe 'GET /api/llm/tiers/:tier/providers/:provider/instances/:instance/models' do
    it 'returns 200 with models for instance' do
      get '/api/llm/tiers/local/providers/ollama/instances/local/models'
      expect(last_response.status).to eq(200)
      result = Legion::JSON.load(last_response.body)
      expect(result[:data][:models]).to be_an(Array)
    end
  end
end
