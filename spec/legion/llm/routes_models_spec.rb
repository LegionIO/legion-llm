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
      allow(Legion::LLM::Discovery).to receive(:discovered_models).and_return([])
      allow(Legion::LLM::Discovery).to receive(:cached_discovered_models).and_return([])
    end

    it 'surfaces the LegionIO auto-routing placeholder model and auto alias' do
      response = get_json('/api/llm/models')
      body = Legion::JSON.load(response.body)

      expect(response.status).to eq(200)
      expect(body[:data][:models]).to include(
        hash_including(id: 'legionio', display_name: 'LegionIO', auto_route: true, default: true)
      )
      expect(body[:data][:models]).to include(
        hash_including(id: 'auto', display_name: 'LegionIO (auto)', auto_route: true)
      )
      expect(body[:data][:offerings]).to include(
        hash_including(model: 'legionio', provider_family: 'legionio', tier: 'auto', transport: 'internal')
      )
      expect(body[:data][:offerings]).to include(
        hash_including(model: 'auto', provider_family: 'legionio', tier: 'auto', transport: 'internal')
      )
    end

    it 'returns a model detail document for the LegionIO placeholder' do
      response = get_json('/api/llm/models/legionio')
      body = Legion::JSON.load(response.body)

      expect(response.status).to eq(200)
      expect(body[:data][:model]).to include(id: 'legionio', display_name: 'LegionIO', auto_route: true)
      expect(body[:data][:offerings].first[:metadata]).to include(auto_route: true, placeholder: true)
    end

    it 'lists normalized model offerings with type filters' do
      Legion::LLM::Inventory.write_lane(lane: {
                                          id: 'cloud:bedrock:default:embed:amazon.titan-embed-text-v2:0', tier: :cloud,
        provider_family: :bedrock, instance_id: :default,
        model: 'amazon.titan-embed-text-v2:0', type: :embed,
        capabilities: [], limits: {}, enabled: true, cost: {}
                                        })

      response = get_json('/api/llm/models?type=embed')
      body = Legion::JSON.load(response.body)

      expect(response.status).to eq(200)
      expect(body[:data][:offerings].map { |offering| offering[:type] }).to eq(['embed'])
      expect(body[:data][:offerings].first[:model]).to eq('amazon.titan-embed-text-v2:0')
      expect(body[:data][:models]).not_to include(hash_including(id: 'legionio'))
    end

    it 'returns all provider offerings under the provider scoped route' do
      Legion::LLM::Inventory.write_lane(lane: {
                                          id: 'direct:vllm:default:inference:qwen3.6-27b', tier: :direct,
        provider_family: :vllm, instance_id: :default,
        model: 'qwen3.6-27b', type: :inference,
        capabilities: [], limits: { context_window: 32_768 }, enabled: true, cost: {}
                                        })

      response = get_json('/api/llm/providers/vllm/models')
      body = Legion::JSON.load(response.body)

      expect(response.status).to eq(200)
      expect(body[:data][:provider]).to eq('vllm')
      expect(body[:data][:offerings].map { |offering| offering[:model] }).to include('qwen3.6-27b')
    end

    it 'returns a model detail document' do
      Legion::LLM::Inventory.write_lane(lane: {
                                          id: 'frontier:anthropic:default:inference:claude-sonnet-4-6', tier: :frontier,
        provider_family: :anthropic, instance_id: :default,
        model: 'claude-sonnet-4-6', type: :inference,
        capabilities: [], limits: {}, enabled: true, cost: {}
                                        })

      response = get_json('/api/llm/models/claude-sonnet-4-6')
      body = Legion::JSON.load(response.body)

      expect(response.status).to eq(200)
      expect(body[:data][:model][:id]).to eq('claude-sonnet-4-6')
      expect(body[:data][:offerings].first[:provider_family].to_s).to eq('anthropic')
    end

    it 'returns 404 for unknown models' do
      response = get_json('/api/llm/models/does-not-exist')
      body = Legion::JSON.load(response.body)

      expect(response.status).to eq(404)
      expect(body[:error][:code]).to eq('model_not_found')
    end

    it 'backs OpenAI-compatible model listing with the same inference inventory' do
      Legion::LLM::Inventory.write_lane(lane: {
                                          id: 'direct:vllm:default:inference:qwen3.6-27b', tier: :direct,
        provider_family: :vllm, instance_id: :default,
        model: 'qwen3.6-27b', type: :inference,
        capabilities: [], limits: { context_window: 32_768 }, enabled: true, cost: {}
                                        })

      response = get_json('/v1/models')
      body = Legion::JSON.load(response.body)

      expect(response.status).to eq(200)
      expect(body[:data]).to include(hash_including(id: 'qwen3.6-27b', owned_by: 'vllm'))
      expect(body[:data]).not_to include(hash_including(id: 'amazon.titan-embed-text-v2:0'))
    end
  end
end
