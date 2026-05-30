# frozen_string_literal: true

require 'spec_helper'
require 'rack/test'
require 'sinatra/base'
require 'sinatra/namespace'

RSpec.describe 'Legion::LLM::API::Namespaces::Native::Instances' do
  include Rack::Test::Methods

  before do
    require 'legion/llm/api/shared_helpers'
    require 'legion/llm/api/namespaces/helpers'
    require 'legion/llm/api/native/instances'
    require 'legion/llm/api/namespaces/native/instances'
  end

  let(:app) do
    Class.new(Sinatra::Base) do
      set :host_authorization, permitted: :any
      register Sinatra::Namespace
      helpers Legion::LLM::API::Namespaces::Helpers

      namespace '/api/llm/instances' do
        register Legion::LLM::API::Namespaces::Native::Instances
      end
    end
  end

  let(:instance_list) do
    [
      { id: 'ollama/local', provider: 'ollama', instance: 'local' },
      { id: 'anthropic/default', provider: 'anthropic', instance: 'default' }
    ]
  end

  before do
    allow(Legion::LLM).to receive(:started?).and_return(true)
    allow(Legion::LLM::API::Native::Instances).to receive(:registry_instances).and_return(instance_list)
  end

  describe 'GET /api/llm/instances' do
    it 'returns 200 with instance list' do
      get '/api/llm/instances'
      expect(last_response.status).to eq(200)
      result = Legion::JSON.load(last_response.body)
      expect(result[:data][:instances].size).to eq(2)
      expect(result[:data][:summary][:total]).to eq(2)
      expect(result[:data][:summary][:providers]).to eq(2)
    end

    it 'returns 503 when LLM not started' do
      allow(Legion::LLM).to receive(:started?).and_return(false)
      get '/api/llm/instances'
      expect(last_response.status).to eq(503)
    end
  end

  describe 'GET /api/llm/instances/:id' do
    it 'returns 200 with known instance' do
      allow(Legion::LLM::API::Native::Instances).to receive(:find_registry_instance).with('ollama/local').and_return(instance_list[0])
      get '/api/llm/instances/ollama/local'
      expect(last_response.status).to eq(200)
      result = Legion::JSON.load(last_response.body)
      expect(result[:data][:instance][:id]).to eq('ollama/local')
    end

    it 'returns 404 when instance not found' do
      allow(Legion::LLM::API::Native::Instances).to receive(:find_registry_instance).with('unknown').and_return(nil)
      get '/api/llm/instances/unknown'
      expect(last_response.status).to eq(404)
      result = Legion::JSON.load(last_response.body)
      expect(result[:error][:code]).to eq('instance_not_found')
    end

    it 'returns 400 for ambiguous instance id' do
      allow(Legion::LLM::API::Native::Instances).to receive(:find_registry_instance).with('local').and_return(:ambiguous)
      get '/api/llm/instances/local'
      expect(last_response.status).to eq(400)
      result = Legion::JSON.load(last_response.body)
      expect(result[:error][:code]).to eq('ambiguous_instance_id')
    end
  end
end
