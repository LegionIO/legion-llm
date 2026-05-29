# frozen_string_literal: true

require 'spec_helper'
require 'rack/test'
require 'sinatra/base'
require 'sinatra/namespace'
require 'legion/llm/api/namespaces/registration'

RSpec.describe 'Phase 3 media namespace registration' do
  include Rack::Test::Methods

  before { allow(Legion::LLM).to receive(:started?).and_return(true) }

  let(:app) do
    a = Class.new(Sinatra::Base)
    Legion::LLM::API::Namespaces::Registration.registered(a)
    a
  end

  it 'mounts POST /v1/images/generations' do
    allow(Legion::LLM::Call::Registry).to receive(:all_instances).and_return([])
    post '/v1/images/generations', Legion::JSON.dump({ prompt: 'cat' }), 'CONTENT_TYPE' => 'application/json'
    # 501 = route found, capability check failed — not 404
    expect(last_response.status).not_to eq(404)
  end

  it 'mounts POST /v1/audio/transcriptions' do
    allow(Legion::LLM::Call::Registry).to receive(:all_instances).and_return([])
    post '/v1/audio/transcriptions', { model: 'whisper-1', file: 'data' }, 'CONTENT_TYPE' => 'multipart/form-data'
    expect(last_response.status).not_to eq(404)
  end

  it 'mounts POST /v1/audio/speech' do
    allow(Legion::LLM::Call::Registry).to receive(:all_instances).and_return([])
    post '/v1/audio/speech', Legion::JSON.dump({ model: 'tts-1', input: 'hi', voice: 'alloy' }), 'CONTENT_TYPE' => 'application/json'
    expect(last_response.status).not_to eq(404)
  end
end
