# frozen_string_literal: true

require 'spec_helper'
require 'rack/test'
require 'sinatra/base'
require 'sinatra/namespace'

RSpec.describe 'Legion::LLM::API::Namespaces::Native::Routing' do
  include Rack::Test::Methods

  before do
    require 'legion/llm/api/shared_helpers'
    require 'legion/llm/api/namespaces/helpers'
    require 'legion/llm/api/namespaces/native/routing'
  end

  let(:app) do
    Class.new(Sinatra::Base) do
      set :host_authorization, permitted: :any
      register Sinatra::Namespace
      helpers Legion::LLM::API::Namespaces::Helpers

      namespace '/api/llm/routing' do
        register Legion::LLM::API::Namespaces::Native::Routing
      end
    end
  end

  let(:mock_rule) do
    double(
      'Rule',
      name:       'test_rule',
      priority:   10,
      conditions: { effort: 'moderate' },
      target:     { tier: 'local' },
      constraint: nil
    )
  end

  before do
    allow(Legion::LLM).to receive(:started?).and_return(true)
    allow(Legion::LLM::Router).to receive(:routing_enabled?).and_return(true)
    allow(Legion::LLM::Router).to receive(:auto_rules_populated?).and_return(true)
    allow(Legion::LLM::Router).to receive(:send).with(:load_rules).and_return([mock_rule])
  end

  describe 'GET /api/llm/routing' do
    it 'returns 200 with routing summary' do
      get '/api/llm/routing'
      expect(last_response.status).to eq(200)
      result = Legion::JSON.load(last_response.body)
      expect(result[:data][:routing_enabled]).to eq(true)
      expect(result[:data][:auto_rules_populated]).to eq(true)
      expect(result[:data][:rules]).to be_an(Array)
      expect(result[:data][:summary][:total]).to eq(1)
    end

    it 'distinguishes auto vs manual rules' do
      auto_rule = double('Rule', name: 'auto:ollama/local/llama3.2', priority: 5,
                                 conditions: {}, target: {}, constraint: nil)
      allow(Legion::LLM::Router).to receive(:send).with(:load_rules).and_return([mock_rule, auto_rule])
      get '/api/llm/routing'
      result = Legion::JSON.load(last_response.body)
      expect(result[:data][:summary][:auto]).to eq(1)
      expect(result[:data][:summary][:manual]).to eq(1)
    end

    it 'marks auto rules in rule list' do
      auto_rule = double('Rule', name: 'auto:ollama/local/llama3.2', priority: 5,
                                 conditions: {}, target: {}, constraint: nil)
      allow(Legion::LLM::Router).to receive(:send).with(:load_rules).and_return([auto_rule])
      get '/api/llm/routing'
      result = Legion::JSON.load(last_response.body)
      expect(result[:data][:rules].first[:auto]).to eq(true)
    end

    it 'returns 503 when LLM not started' do
      allow(Legion::LLM).to receive(:started?).and_return(false)
      get '/api/llm/routing'
      expect(last_response.status).to eq(503)
    end
  end
end
