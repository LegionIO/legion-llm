# frozen_string_literal: true

require 'spec_helper'
begin
  require 'sinatra/base'
  require 'legion/llm/api/namespaces/native/tiers'
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

    # SSOT v3: offerings live in the Phase 1 Registry (new store), not the
    # legacy Concurrent::Map lane store — the endpoints project the snapshot.
    before do
      allow(Legion::LLM).to receive(:started?).and_return(true)
      allow(Legion::LLM::Discovery).to receive(:discovered_models).and_return([])
      allow(Legion::LLM::Discovery).to receive(:cached_discovered_models).and_return([])
      SsotV3SnapshotFactory.activate(
        provider_family: :vllm,
        instance_id:     'vllm-gpu-01',
        drafts:          [
          SsotV3SnapshotFactory.offering_draft(
            model: 'qwen3.6-27b', tier: :fleet, supported: %i[chat stream_chat], context: 32_768
          )
        ]
      )
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
      key = SsotV3SnapshotFactory.instance_key(provider_family: :vllm, instance_id: 'vllm-gpu-01')
      offering_id = SsotV3SnapshotFactory.snapshot.offerings_for(instance_key: key).first.offering_id

      response = get_json("/api/llm/offerings/#{Rack::Utils.escape_path(offering_id)}")
      body = Legion::JSON.load(response.body)

      expect(response.status).to eq(200)
      expect(body[:data][:offering]).not_to be_nil
      expect(body[:data][:offering][:model]).to eq('qwen3.6-27b')
      expect(body[:data][:offering][:health]).to include(available: true, circuit_state: 'closed')
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

    describe 'D14 settings health display' do
      before do
        Legion::LLM::Call::Registry.register(:vllm, double('vllm-adapter'), instance: :'vllm-gpu-01')
        extensions = Legion::Settings.loader.settings[:extensions] ||= {}
        extensions[:llm] ||= {}
        extensions[:llm][:vllm] = {
          instances: {
            'vllm-gpu-01': {
              health:       {
                circuit_state: :closed, denied: false, available: true, adjustment: 0,
                reason: 'startup readiness succeeded', last_probe_outcome: :success, source: :ssot_discovery_actor
              },
              capabilities: %w[completion streaming]
            }
          }
        }
      end

      it 'surfaces the actor-written health hash on /api/llm/instances' do
        response = get_json('/api/llm/instances/vllm/vllm-gpu-01')
        body = Legion::JSON.load(response.body)

        expect(response.status).to eq(200)
        expect(body[:data][:instance][:health]).to include(
          available: true, circuit_state: 'closed', adjustment: 0, source: 'ssot_discovery_actor'
        )
      end

      it 'projects the tier tree from the Registry snapshot with instance availability' do
        # The namespace tiers route serves a 30s display cache — reset it so
        # this example sees the registry state published in `before`.
        Legion::LLM::API::Namespaces::Native::Tiers.reset_cache!

        response = get_json('/api/llm/tiers')
        body = Legion::JSON.load(response.body)

        expect(response.status).to eq(200)
        fleet = body[:data][:tiers][:fleet]
        expect(fleet).not_to be_nil
        instance = fleet[:providers][:vllm][:instances][:'vllm-gpu-01']
        expect(instance[:health]).to eq('closed')
        expect(instance[:capabilities]).to include('completion', 'streaming')
        expect(instance[:models].map { |m| m[:id] }).to include('qwen3.6-27b')
      end
    end

    describe 'routing status' do
      it 'reports routing enabled when the Registry has a complete publication' do
        response = get_json('/api/llm/routing')
        body = Legion::JSON.load(response.body)

        expect(response.status).to eq(200)
        expect(body[:data][:routing_enabled]).to eq(true)
      end
    end
  end
end
