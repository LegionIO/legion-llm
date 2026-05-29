# frozen_string_literal: true

require 'spec_helper'
require 'rack/test'
require 'sinatra/base'
require 'legion/llm/api/namespaces/registration'

RSpec.describe 'Anthropic Namespace Integration' do
  include Rack::Test::Methods

  let(:app) do
    klass = Class.new(Sinatra::Base)
    klass.set :host_authorization, permitted: :any
    Legion::LLM::API::Namespaces::Registration.registered(klass)
    klass
  end

  before do
    allow(Legion::LLM).to receive(:started?).and_return(true)
    allow(Legion::LLM::Inventory).to receive(:offerings).and_return([
                                                                      { model: 'legionio', type: :inference, provider_family: 'legionio', instance_id: 'auto',
capabilities: %w[chat tools], limits: {}, enabled: true }
                                                                    ])
  end

  it 'responds to POST /v1/messages' do
    mock_executor = instance_double(Legion::LLM::Inference::Executor)
    mock_response = instance_double(Legion::LLM::Inference::Response,
                                    message: { content: 'hi' }, routing: { model: 'legionio' },
                                    tokens: { input: 5, output: 2 }, tools: nil, stop: { reason: 'end_turn' })
    allow(mock_response).to receive(:respond_to?).and_return(true)
    allow(Legion::LLM::Inference::Executor).to receive(:new).and_return(mock_executor)
    allow(mock_executor).to receive(:call).and_return(mock_response)

    post '/v1/messages', Legion::JSON.dump({ model: 'legionio', messages: [{ role: 'user', content: 'hi' }], max_tokens: 100 }),
         'CONTENT_TYPE' => 'application/json'
    expect(last_response.status).to eq(200)
  end

  it 'responds to POST /v1/messages/count_tokens' do
    post '/v1/messages/count_tokens', Legion::JSON.dump({ model: 'legionio', messages: [{ role: 'user', content: 'hi' }], max_tokens: 100 }),
         'CONTENT_TYPE' => 'application/json'
    expect(last_response.status).to eq(200)
    body = Legion::JSON.load(last_response.body)
    expect(body[:input_tokens]).to be_a(Integer)
  end

  it 'responds to GET /v1/messages/batches' do
    get '/v1/messages/batches'
    expect(last_response.status).to eq(200)
  end

  # /v1/models is handled by OpenAI::Models (Phase 2A) — no separate Anthropic route.
  # Anthropic clients get Anthropic-format responses via anthropic_client?(env) branch.
  # Skipped until Phase 2A registers the /v1/models namespace.
  xit 'responds to GET /v1/models (any client)' do
    get '/v1/models'
    expect(last_response.status).to eq(200)
  end
end
