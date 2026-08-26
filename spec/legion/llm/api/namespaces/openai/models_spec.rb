# frozen_string_literal: true

require 'spec_helper'
require 'rack/test'
require 'sinatra/base'
require 'sinatra/namespace'
require 'legion/llm/api/namespaces/helpers'

# SSOT v3 Task 16: the maintained /v1/models tree is projected by ModelCatalog
# from ONE Registry snapshot + ONE SettingsState generation captured per request.
# These specs activate offerings through the released Phase 1 Registry (via the
# SsotV3SnapshotFactory) rather than stubbing the legacy Inventory facade.
RSpec.describe 'Namespaces::OpenAI::Models', :ssot_v3 do
  include Rack::Test::Methods

  before { require 'legion/llm/api/namespaces/openai/models' }

  let(:app) do
    Class.new(Sinatra::Base) do
      set :host_authorization, permitted: :any
      register Sinatra::Namespace
      helpers Legion::Logging::Helper
      helpers Legion::LLM::API::Namespaces::Helpers
      register Legion::LLM::API::Namespaces::OpenAI::Models
    end
  end

  before do
    allow(Legion::LLM).to receive(:started?).and_return(true)
    Legion::LLM::Routing::SettingsState.reset!
    Legion::Settings.loader.settings[:extensions] ||= {}
    Legion::Settings.loader.settings[:extensions][:llm] ||= {}
  end

  after { Legion::LLM::Routing::SettingsState.reset! }

  # Activate one chat-capable offering so the compat set is non-empty and the
  # auto-routing aliases (legionio/auto/copilot-utility-small) are appended.
  def activate_chat_model(model:, provider_family: 'vllm', instance_id: 'h200')
    activate(
      provider_family: provider_family, instance_id: instance_id,
      drafts: [offering_draft(model: model, tier: :local, supported: %i[chat])]
    )
  end

  describe 'GET /v1/models' do
    it 'returns OpenAI model list format with the activated model' do
      activate_chat_model(model: 'llama3.2')
      get '/v1/models'
      expect(last_response.status).to eq(200)
      body = Legion::JSON.load(last_response.body)
      expect(body[:object]).to eq('list')
      expect(body[:data]).to be_an(Array)
      ids = body[:data].map { |m| m[:id] }
      expect(ids).to include('llama3.2')
    end

    it 'appends the auto-routing aliases when the compat set is non-empty' do
      activate_chat_model(model: 'llama3.2')
      get '/v1/models'
      ids = Legion::JSON.load(last_response.body)[:data].map { |m| m[:id] }
      expect(ids).to include('copilot-utility-small')
    end

    it 'deduplicates a model published by two providers' do
      activate_chat_model(model: 'llama3.2', provider_family: 'vllm', instance_id: 'h200')
      activate_chat_model(model: 'llama3.2', provider_family: 'ollama', instance_id: 'local')
      get '/v1/models'
      body = Legion::JSON.load(last_response.body)
      expect(body[:data].map { |m| m[:id] }.tally['llama3.2']).to eq(1)
    end

    it 'returns an empty compat list when nothing is activated' do
      get '/v1/models'
      expect(last_response.status).to eq(200)
      body = Legion::JSON.load(last_response.body)
      expect(body[:data]).to eq([])
    end
  end

  describe 'GET /v1/models/:id' do
    it 'returns the model when it is catalog-visible' do
      activate_chat_model(model: 'llama3.2')
      get '/v1/models/llama3.2'
      expect(last_response.status).to eq(200)
      body = Legion::JSON.load(last_response.body)
      expect(body[:id]).to eq('llama3.2')
      expect(body[:object]).to eq('model')
    end

    it 'returns 404 for an unknown model when the compat set is empty' do
      get '/v1/models/no-such-model'
      expect(last_response.status).to eq(404)
      body = Legion::JSON.load(last_response.body)
      expect(body[:error][:type]).to eq('invalid_request_error')
      expect(body[:error][:code]).to eq('model_not_found')
    end

    it 'returns 200 for copilot-utility-small when a usable inference offering exists' do
      activate_chat_model(model: 'gemma4')
      get '/v1/models/copilot-utility-small'
      expect(last_response.status).to eq(200)
      body = Legion::JSON.load(last_response.body)
      expect(body[:id]).to eq('copilot-utility-small')
      expect(body[:object]).to eq('model')
      expect(body[:owned_by]).to eq('legionio')
    end

    it 'returns 404 for copilot-utility-small when no usable offering exists' do
      get '/v1/models/copilot-utility-small'
      expect(last_response.status).to eq(404)
    end
  end

  describe 'DELETE /v1/models/:id' do
    it 'returns deleted stub' do
      delete '/v1/models/my-fine-tune'
      expect(last_response.status).to eq(200)
      body = Legion::JSON.load(last_response.body)
      expect(body[:deleted]).to be(true)
      expect(body[:id]).to eq('my-fine-tune')
    end
  end

  describe 'Anthropic client format (anthropic-version header)' do
    it 'GET /v1/models returns Anthropic list format' do
      activate_chat_model(model: 'llama3.2')
      get '/v1/models', {}, { 'HTTP_ANTHROPIC_VERSION' => '2023-06-01' }
      expect(last_response.status).to eq(200)
      body = Legion::JSON.load(last_response.body)
      expect(body[:has_more]).to eq(false)
      expect(body[:data]).to be_an(Array)
      expect(body[:data].first[:type]).to eq('model')
      expect(body[:data].first[:display_name]).to be_a(String)
      expect(body[:data].first[:created_at]).to be_a(String)
      expect(body.keys).not_to include(:object)
    end

    it 'GET /v1/models/:id returns Anthropic model object' do
      activate_chat_model(model: 'llama3.2')
      get '/v1/models/llama3.2', {}, { 'HTTP_ANTHROPIC_VERSION' => '2023-06-01' }
      expect(last_response.status).to eq(200)
      body = Legion::JSON.load(last_response.body)
      expect(body[:id]).to eq('llama3.2')
      expect(body[:type]).to eq('model')
      expect(body[:display_name]).to be_a(String)
      expect(body.keys).not_to include(:object)
    end
  end
end
