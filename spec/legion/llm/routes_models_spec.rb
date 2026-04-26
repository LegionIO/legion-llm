# frozen_string_literal: true

require 'spec_helper'
begin
  require 'sinatra/base'
rescue LoadError
  nil
end

if defined?(Sinatra::Base) && defined?(Legion::LLM::Routes)
  RSpec.describe 'LLM native model inventory routes' do
    let(:test_app) do
      Class.new(Sinatra::Base) do
        set :show_exceptions, false
        set :raise_errors, false
        set :host_authorization, permitted: :any

        register Legion::LLM::Routes
      end
    end

    def app
      test_app
    end

    def get_json(path)
      Rack::MockRequest.new(app).get(path)
    end

    before do
      allow(Legion::LLM).to receive(:started?).and_return(true)
      allow(Legion::LLM::Discovery::Ollama).to receive(:models).and_return([])
      allow(Legion::LLM::Discovery::Vllm).to receive(:models).and_return([])
    end

    it 'lists normalized model offerings with type filters' do
      Legion::Settings[:llm][:providers][:bedrock][:enabled] = true

      response = get_json('/api/llm/models?type=embed')
      body = Legion::JSON.load(response.body)

      expect(response.status).to eq(200)
      expect(body[:data][:offerings].map { |offering| offering[:type] }).to eq(['embed'])
      expect(body[:data][:offerings].first[:model]).to eq('amazon.titan-embed-text-v2:0')
    end

    it 'returns all provider offerings under the provider scoped route' do
      Legion::Settings[:llm][:providers][:vllm][:enabled] = true
      allow(Legion::LLM::Discovery::Vllm).to receive(:models).and_return([
                                                                           { id:            'qwen3.6-27b',
                                                                             max_model_len: 32_768 }
                                                                         ])

      response = get_json('/api/llm/providers/vllm/models')
      body = Legion::JSON.load(response.body)

      expect(response.status).to eq(200)
      expect(body[:data][:provider]).to eq('vllm')
      expect(body[:data][:offerings].map { |offering| offering[:model] }).to include('qwen3.6-27b')
    end

    it 'returns a model detail document' do
      Legion::Settings[:llm][:providers][:anthropic][:enabled] = true

      response = get_json('/api/llm/models/claude-sonnet-4-6')
      body = Legion::JSON.load(response.body)

      expect(response.status).to eq(200)
      expect(body[:data][:model][:id]).to eq('claude-sonnet-4-6')
      expect(body[:data][:offerings].first[:provider_family]).to eq('anthropic')
    end

    it 'returns 404 for unknown models' do
      response = get_json('/api/llm/models/does-not-exist')
      body = Legion::JSON.load(response.body)

      expect(response.status).to eq(404)
      expect(body[:error][:code]).to eq('model_not_found')
    end

    it 'backs OpenAI-compatible model listing with the same inference inventory' do
      Legion::Settings[:llm][:providers][:vllm][:enabled] = true
      allow(Legion::LLM::Discovery::Vllm).to receive(:models).and_return([
                                                                           { id:            'qwen3.6-27b',
                                                                             max_model_len: 32_768 }
                                                                         ])

      response = get_json('/v1/models')
      body = Legion::JSON.load(response.body)

      expect(response.status).to eq(200)
      expect(body[:data]).to include(hash_including(id: 'qwen3.6-27b', owned_by: 'vllm'))
      expect(body[:data]).not_to include(hash_including(id: 'amazon.titan-embed-text-v2:0'))
    end
  end
end
