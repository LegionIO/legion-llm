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
  end

  describe 'GET /api/llm/routing' do
    it 'returns 200 with routing summary (rule engine removed in P4)' do
      get '/api/llm/routing'
      expect(last_response.status).to eq(200)
      result = Legion::JSON.load(last_response.body)
      expect(result[:data][:routing_enabled]).to eq(false)
      expect(result[:data][:rules]).to eq([])
      expect(result[:data][:summary][:total]).to eq(0)
    end

    it 'returns empty rules list' do
      get '/api/llm/routing'
      result = Legion::JSON.load(last_response.body)
      expect(result[:data][:rules]).to eq([])
    end

    it 'returns zero summary counts' do
      get '/api/llm/routing'
      result = Legion::JSON.load(last_response.body)
      expect(result[:data][:summary][:auto]).to eq(0)
      expect(result[:data][:summary][:manual]).to eq(0)
    end

    it 'returns 503 when LLM not started' do
      allow(Legion::LLM).to receive(:started?).and_return(false)
      get '/api/llm/routing'
      expect(last_response.status).to eq(503)
    end
  end
end
