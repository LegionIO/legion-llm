# frozen_string_literal: true

require 'spec_helper'
begin
  require 'sinatra/base'
rescue LoadError
  nil
end

if defined?(Sinatra::Base) && defined?(Legion::LLM::Routes)
  RSpec.describe 'LLM native provider routes' do
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

    it 'lists providers from Registry' do
      stub_mod = Module.new
      Legion::LLM::Call::Registry.register(:bedrock, stub_mod, instance: :default,
                                                               metadata: { tier:         :cloud,
                                                                           capabilities: [:chat] })

      response = get_json('/api/llm/providers')
      body = Legion::JSON.load(response.body)

      expect(response.status).to eq(200)
      expect(body[:data][:providers]).to include(hash_including(provider: 'bedrock',
                                                                instance: 'default',
                                                                native:   true))
    end

    it 'returns empty list when no providers are registered' do
      response = get_json('/api/llm/providers')
      body = Legion::JSON.load(response.body)

      expect(response.status).to eq(200)
      expect(body[:data][:providers]).to eq([])
      expect(body[:data][:summary][:total]).to eq(0)
    end

    it 'includes tier and capabilities from metadata' do
      stub_mod = Module.new
      Legion::LLM::Call::Registry.register(:ollama, stub_mod, instance: :local1,
                                                              metadata: { tier:         :local,
                                                                          capabilities: %i[chat embeddings] })

      response = get_json('/api/llm/providers')
      body = Legion::JSON.load(response.body)

      entry = body[:data][:providers].find { |p| p[:provider] == 'ollama' }
      expect(entry[:tier]).to eq('local')
      expect(entry[:capabilities]).to include('chat', 'embeddings')
    end

    it 'returns provider instances by name' do
      stub_mod = Module.new
      Legion::LLM::Call::Registry.register(:bedrock, stub_mod, instance: :east,
                                                               metadata: { tier: :cloud })
      Legion::LLM::Call::Registry.register(:bedrock, stub_mod, instance: :west,
                                                               metadata: { tier: :cloud })

      response = get_json('/api/llm/providers/bedrock')
      body = Legion::JSON.load(response.body)

      expect(response.status).to eq(200)
      expect(body[:data][:provider]).to eq('bedrock')
      expect(body[:data][:instances].size).to eq(2)
    end

    it 'returns 404 for unknown provider' do
      response = get_json('/api/llm/providers/nonexistent')
      body = Legion::JSON.load(response.body)

      expect(response.status).to eq(404)
      expect(body[:error][:code]).to eq('provider_not_found')
    end

    # D14: display health/capabilities come from the per-instance settings hash
    # the provider's discovery actor writes after each registry commit — not
    # the (no longer populated) legacy lane store.
    it 'surfaces the actor-written settings health hash and capabilities' do
      stub_mod = Module.new
      Legion::LLM::Call::Registry.register(:vllm, stub_mod, instance: :apollo,
                                                            metadata: { tier: :fleet, capabilities: %i[chat] })
      extensions = Legion::Settings.loader.settings[:extensions] ||= {}
      extensions[:llm] ||= {}
      extensions[:llm][:vllm] = {
        instances: {
          apollo: {
            tier:         :fleet,
            health:       {
              circuit_state: :open, denied: false, available: false, adjustment: -50,
              reason: 'Vertex models-list returned 403', last_probe_outcome: :failure, source: :ssot_discovery_actor
            },
            capabilities: %w[completion streaming embedding]
          }
        }
      }

      response = get_json('/api/llm/providers/vllm')
      body = Legion::JSON.load(response.body)

      expect(response.status).to eq(200)
      entry = body[:data][:instances].find { |p| p[:instance] == 'apollo' }
      expect(entry[:health]).to include(
        available: false, circuit_state: 'open', adjustment: -50, source: 'ssot_discovery_actor'
      )
      expect(entry[:capabilities]).to eq(%w[completion streaming embedding])
      expect(entry[:tier]).to eq('fleet')
    end

    it 'reports empty health before the actor has committed (cold boot)' do
      stub_mod = Module.new
      Legion::LLM::Call::Registry.register(:bedrock, stub_mod, instance: :cold,
                                                               metadata: { tier: :cloud })

      response = get_json('/api/llm/providers/bedrock')
      body = Legion::JSON.load(response.body)

      entry = body[:data][:instances].find { |p| p[:instance] == 'cold' }
      expect(entry[:health]).to eq({})
      expect(entry[:capabilities]).to eq([])
    end
  end
end
