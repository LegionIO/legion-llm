# frozen_string_literal: true

require 'spec_helper'
begin
  require 'sinatra/base'
rescue LoadError
  nil
end

if defined?(Sinatra::Base) && defined?(Legion::LLM::Routes)
  RSpec.describe 'LLM native offering and instance routes' do
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
      Legion::LLM::Inventory.write_lane(lane: {
                                          id:              'fleet:vllm:vllm_gpu_01:inference:qwen3.6-27b',
                                          tier:            :fleet,
                                          provider_family: :vllm,
                                          instance_id:     :'vllm-gpu-01',
                                          model:           'qwen3.6-27b',
                                          type:            :inference,
                                          capabilities:    [],
                                          limits:          { context_window: 32_768 },
                                          enabled:         true,
                                          cost:            {}
                                        })
    end

    after do
      Legion::LLM::Call::Registry.reset!
    end

    it 'lists offerings with operation and model filters' do
      response = get_json('/api/llm/offerings?operation=inference&model=qwen3.6-27b')
      body = Legion::JSON.load(response.body)

      expect(response.status).to eq(200)
      expect(body[:data][:summary]).to include(total: 1)

      offerings_tree = body[:data][:offerings]
      all_offerings = offerings_tree.values.flat_map { |providers| providers.values.flat_map { |instances| instances.values.flatten } }
      expect(all_offerings.size).to eq(1)
      expect(all_offerings.first[:model]).to eq('qwen3.6-27b')
    end

    it 'returns offering details by offering id' do
      lane = Legion::LLM::Inventory.offerings(model: 'qwen3.6-27b').first
      offering_id = lane[:offering_id] || lane[:id]

      response = get_json("/api/llm/offerings/#{Rack::Utils.escape_path(offering_id)}")
      body = Legion::JSON.load(response.body)

      expect(response.status).to eq(200)
      expect(body[:data][:offering]).not_to be_nil
    end

    it 'lists registered instances from the Registry' do
      Legion::LLM::Call::Registry.register(:vllm, double('vllm-adapter'), instance: :'vllm-gpu-01')

      response = get_json('/api/llm/instances')
      body = Legion::JSON.load(response.body)

      expect(response.status).to eq(200)
      instance = body[:data][:instances].find { |row| row[:instance] == 'vllm-gpu-01' }
      expect(instance).to include(id: 'vllm/vllm-gpu-01', provider: 'vllm', instance: 'vllm-gpu-01')
      expect(body[:data][:summary]).to include(total: a_kind_of(Integer))
    end

    it 'returns a single registered instance by composite id' do
      Legion::LLM::Call::Registry.register(:vllm, double('vllm-adapter'), instance: :'vllm-gpu-01')

      response = get_json('/api/llm/instances/vllm-gpu-01')
      body = Legion::JSON.load(response.body)

      expect(response.status).to eq(200)
      expect(body[:data][:instance]).to include(provider: 'vllm', instance: 'vllm-gpu-01')
    end
  end
end
