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
      allow(Legion::LLM::Discovery::Ollama).to receive(:models).and_return([])
      allow(Legion::LLM::Discovery::Vllm).to receive(:models).and_return([])
    end

    it 'lists string-keyed enabled providers' do
      Legion::Settings[:llm][:providers]['bedrock-json'] = {
        'enabled'       => true,
        'default_model' => 'claude-sonnet-4-6',
        'api_key'       => 'dead-key'
      }

      response = get_json('/api/llm/providers')
      body = Legion::JSON.load(response.body)

      expect(response.status).to eq(200)
      expect(body[:data][:providers]).to include(hash_including(name:          'bedrock-json',
                                                                default_model: 'claude-sonnet-4-6'))
    end

    it 'lists providers from top-level string-keyed provider settings' do
      Legion::Settings[:llm]['providers'] = {
        'bedrock-json' => {
          'enabled'       => true,
          'default_model' => 'claude-sonnet-4-6'
        }
      }

      response = get_json('/api/llm/providers')
      body = Legion::JSON.load(response.body)

      expect(response.status).to eq(200)
      expect(body[:data][:providers]).to include(hash_including(name: 'bedrock-json'))
    end

    it 'redacts string-keyed secrets from provider details' do
      Legion::Settings[:llm][:providers]['bedrock-json'] = {
        'enabled'       => true,
        'default_model' => 'claude-sonnet-4-6',
        'api_key'       => 'dead-key',
        'bearer_token'  => 'dead-bearer',
        'region'        => 'us-east-2',
        'instances'     => {
          'bedrock1' => {
            'enabled' => true,
            'api_key' => 'nested-dead-key',
            'region'  => 'us-east-1'
          }
        }
      }

      response = get_json('/api/llm/providers/bedrock-json')
      body = Legion::JSON.load(response.body)

      expect(response.status).to eq(200)
      expect(body[:data][:config]).to include(region: 'us-east-2')
      expect(body[:data][:config]).not_to have_key(:api_key)
      expect(body[:data][:config]).not_to have_key(:bearer_token)
      expect(body[:data][:config][:instances][:bedrock1]).to include(region: 'us-east-1')
      expect(body[:data][:config][:instances][:bedrock1]).not_to have_key(:api_key)
    end

    it 'hides disabled string-keyed providers' do
      Legion::Settings[:llm][:providers]['disabled-provider'] = {
        'enabled'       => false,
        'default_model' => 'hidden'
      }

      response = get_json('/api/llm/providers/disabled-provider')
      body = Legion::JSON.load(response.body)

      expect(response.status).to eq(404)
      expect(body[:error][:code]).to eq('provider_not_found')
    end
  end
end
