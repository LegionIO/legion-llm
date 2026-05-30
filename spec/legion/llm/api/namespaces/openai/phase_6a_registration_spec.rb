# frozen_string_literal: true

require 'spec_helper'
require 'rack/test'
require 'sinatra/base'
require 'sinatra/namespace'
require 'legion/llm/api/namespaces/registration'

RSpec.describe 'Phase 6A namespace registration' do
  include Rack::Test::Methods

  before do
    allow(Legion::LLM).to receive(:started?).and_return(true)
  end

  let(:app) do
    a = Class.new(Sinatra::Base)
    Legion::LLM::API::Namespaces::Registration.registered(a)
    a
  end

  it 'mounts POST /v1/conversations' do
    post '/v1/conversations', '{}', 'CONTENT_TYPE' => 'application/json'
    expect(last_response.status).not_to eq(404)
  end

  it 'mounts GET /v1/batches' do
    get '/v1/batches'
    expect(last_response.status).not_to eq(404)
  end

  it 'mounts POST /v1/files' do
    post '/v1/files', { purpose: 'assistants' }
    expect(last_response.status).not_to eq(404)
  end

  it 'mounts POST /v1/uploads' do
    post '/v1/uploads', '{}', 'CONTENT_TYPE' => 'application/json'
    expect(last_response.status).not_to eq(404)
  end

  it 'mounts GET /v1/conversations/:id/items' do
    get '/v1/conversations/conv_test/items'
    expect(last_response.status).not_to eq(404)
  end

  it 'mounts POST /v1/uploads/:id/parts' do
    post '/v1/uploads/upload_test/parts', 'data', 'CONTENT_TYPE' => 'application/octet-stream'
    expect(last_response.status).not_to eq(404)
  end
end
