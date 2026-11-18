# frozen_string_literal: true

require 'spec_helper'
begin
  require 'sinatra/base'
rescue LoadError
  nil
end

if defined?(Sinatra::Base) && defined?(Legion::LLM::Routes)
  RSpec.describe 'LLM native provider routes', :ssot_v3 do
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
      Legion::LLM::Call::Registry.reset!
    end

    after do
      Legion::LLM::Call::Registry.reset!
    end

    def publish_provider(provider, instance, tier: :cloud, capabilities: {})
      activate(provider_family: provider, instance_id: instance, drafts: [
                 offering_draft(model: 'test-model', tier: tier, capabilities: capabilities)
               ])
    end

    it 'lists providers from Inventory' do
      publish_provider('bedrock', 'default')
      response = get_json('/api/llm/providers')
      body = Legion::JSON.load(response.body)

      expect(response.status).to eq(200)
      expect(body[:data][:providers]).to include(hash_including(provider: 'bedrock', instance: 'default', native: true))
    end

    it 'returns an empty list when no instances have been published' do
      response = get_json('/api/llm/providers')
      body = Legion::JSON.load(response.body)

      expect(response.status).to eq(200)
      expect(body[:data][:providers]).to eq([])
      expect(body[:data][:summary][:total]).to eq(0)
    end

    it 'reads tier and capabilities from published evidence' do
      publish_provider('ollama', 'local1', tier: :local, capabilities: { completion: :supported, embedding: :supported })
      response = get_json('/api/llm/providers')
      entry = Legion::JSON.load(response.body).dig(:data, :providers).first

      expect(entry[:tier]).to eq('local')
      expect(entry[:capabilities]).to include('completion', 'embedding')
    end

    it 'returns published provider instances by name' do
      publish_provider('bedrock', 'east')
      publish_provider('bedrock', 'west')
      response = get_json('/api/llm/providers/bedrock')
      body = Legion::JSON.load(response.body)

      expect(response.status).to eq(200)
      expect(body[:data][:provider]).to eq('bedrock')
      expect(body[:data][:instances].size).to eq(2)
    end

    it 'returns 404 for unknown providers' do
      response = get_json('/api/llm/providers/nonexistent')
      expect(response.status).to eq(404)
      expect(Legion::JSON.load(response.body).dig(:error, :code)).to eq('provider_not_found')
    end

    it 'reflects unavailable published instances without depending on settings writeback' do
      publish_provider('vllm', 'primary', tier: :direct, capabilities: { streaming: :supported })
      mark_unavailable(provider_family: 'vllm', instance_id: 'primary',
                       publisher_token_id: snapshot.instance(instance_key: instance_key(provider_family: 'vllm', instance_id: 'primary')).publisher_token_id)
      response = get_json('/api/llm/providers/vllm')
      entry = Legion::JSON.load(response.body).dig(:data, :instances).first

      expect(response.status).to eq(200)
      expect(entry[:health]).to include(state: 'unavailable', source: 'dispatch')
      expect(entry[:capabilities]).to include('streaming')
      expect(entry[:tier]).to eq('direct')
    end

    it 'keeps an unactivated claim outside the published provider catalog' do
      claim_only(provider_family: 'bedrock', instance_id: 'cold')
      response = get_json('/api/llm/providers/bedrock')

      expect(response.status).to eq(404)
      expect(Legion::JSON.load(response.body).dig(:error, :code)).to eq('provider_not_found')
    end
  end
end
