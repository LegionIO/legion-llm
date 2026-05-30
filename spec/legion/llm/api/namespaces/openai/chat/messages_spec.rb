# frozen_string_literal: true

require 'spec_helper'
require 'rack/test'
require 'sinatra/base'
require 'sinatra/namespace'
require 'legion/llm/api/namespaces/helpers'

RSpec.describe 'Namespaces::OpenAI::Chat::Messages' do
  include Rack::Test::Methods

  before { require 'legion/llm/api/namespaces/openai/chat/messages' }

  let(:app) do
    Class.new(Sinatra::Base) do
      set :host_authorization, permitted: :any
      register Sinatra::Namespace
      helpers Legion::Logging::Helper
      helpers Legion::LLM::API::Namespaces::Helpers
      register Legion::LLM::API::Namespaces::OpenAI::Chat::Messages
    end
  end

  describe 'GET /v1/chat/completions/:completion_id/messages' do
    it 'returns empty list for any completion_id' do
      get '/v1/chat/completions/chatcmpl-abc123/messages'
      expect(last_response.status).to eq(200)
      body = Legion::JSON.load(last_response.body)
      expect(body[:object]).to eq('list')
      expect(body[:data]).to be_an(Array)
    end

    it 'includes the completion_id in first_id/last_id when data is present' do
      get '/v1/chat/completions/chatcmpl-xyz/messages'
      expect(last_response.status).to eq(200)
    end
  end
end
