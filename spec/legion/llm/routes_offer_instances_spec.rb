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
      allow(Legion::LLM::Discovery::Ollama).to receive(:models).and_return([])
      allow(Legion::LLM::Discovery::Vllm).to receive(:models).and_return([])
      Legion::Settings[:llm][:providers][:vllm] = {
        enabled:   true,
        instances: {
          'vllm-gpu-01' => {
            enabled: true,
            models:  [
              {
                model:          'qwen3.6-27b',
                type:           :inference,
                context_window: 32_768,
                tier:           :fleet
              }
            ]
          }
        }
      }
    end

    it 'lists offerings with operation and model filters' do
      response = get_json('/api/llm/offerings?operation=inference&model=qwen3.6-27b')
      body = Legion::JSON.load(response.body)

      expect(response.status).to eq(200)
      expect(body[:data][:summary]).to include(total: 1, operation: 'inference')
      expect(body[:data][:offerings].first).to include(
        model:             'qwen3.6-27b',
        provider_family:   'vllm',
        provider_instance: 'vllm-gpu-01',
        instance_id:       'vllm-gpu-01'
      )
    end

    it 'returns offering details by offering id' do
      offering_id = Legion::LLM::Inventory.offerings(model: 'qwen3.6-27b').first.fetch(:offering_id)

      response = get_json("/api/llm/offerings/#{Rack::Utils.escape_path(offering_id)}")
      body = Legion::JSON.load(response.body)

      expect(response.status).to eq(200)
      expect(body[:data][:offering][:offering_id]).to eq(offering_id)
    end

    it 'lists provider instances with capacity and offerings' do
      response = get_json('/api/llm/instances')
      body = Legion::JSON.load(response.body)

      expect(response.status).to eq(200)
      instance = body[:data][:instances].find { |row| row[:instance_id] == 'vllm-gpu-01' }
      expect(instance[:capacity]).to include(max_context_window: 32_768, offering_count: 1)
      expect(instance[:offerings].first[:model]).to eq('qwen3.6-27b')
    end

    it 'returns provider instance details' do
      response = get_json('/api/llm/instances/vllm-gpu-01')
      body = Legion::JSON.load(response.body)

      expect(response.status).to eq(200)
      expect(body[:data][:instance]).to include(instance_id: 'vllm-gpu-01', provider_family: 'vllm')
    end
  end
end
