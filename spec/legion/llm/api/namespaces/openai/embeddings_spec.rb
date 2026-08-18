# frozen_string_literal: true

require 'spec_helper'
require 'rack/test'
require 'sinatra/base'
require 'sinatra/namespace'
require 'legion/llm/api/namespaces/helpers'
require 'legion/llm/api/translators/openai_response'

RSpec.describe 'Namespaces::OpenAI::Embeddings' do
  include Rack::Test::Methods

  before { require 'legion/llm/api/namespaces/openai/embeddings' }

  let(:app) do
    Class.new(Sinatra::Base) do
      set :host_authorization, permitted: :any
      register Sinatra::Namespace
      helpers Legion::Logging::Helper
      helpers Legion::LLM::API::Namespaces::Helpers
      register Legion::LLM::API::Namespaces::OpenAI::Embeddings
    end
  end

  before do
    allow(Legion::LLM).to receive(:started?).and_return(true)
    Legion::Settings[:llm][:default_model] = 'legionio'
    allow(Legion::LLM).to receive(:embed).and_return([0.1, 0.2, 0.3])
  end

  describe 'POST /v1/embeddings' do
    it 'returns 400 with the complete OpenAI error envelope when input is missing' do
      post '/v1/embeddings', Legion::JSON.dump({ model: 'legionio' }), 'CONTENT_TYPE' => 'application/json'
      expect(last_response.status).to eq(400)
      body = Legion::JSON.load(last_response.body)
      expect(body[:error][:type]).to eq('invalid_request_error')
      # OpenAI error objects ALWAYS carry param and code (null when N/A).
      expect(body[:error].key?(:param)).to be(true)
      expect(body[:error].key?(:code)).to be(true)
      expect(body[:error][:param]).to eq('input')
      expect(body[:error][:code]).to be_nil
    end

    it 'returns embedding vector in OpenAI format' do
      post '/v1/embeddings',
           Legion::JSON.dump({ input: 'Hello world', model: 'legionio' }),
           'CONTENT_TYPE' => 'application/json'
      expect(last_response.status).to eq(200)
      body = Legion::JSON.load(last_response.body)
      expect(body[:object]).to eq('list')
      expect(body[:data]).to be_an(Array)
      expect(body[:data].first[:object]).to eq('embedding')
      expect(body[:data].first[:embedding]).to eq([0.1, 0.2, 0.3])
      expect(body[:model]).to eq('legionio')
    end

    # OpenAI contract: N input strings -> N data entries, sequential index,
    # input order preserved (the old "collapse to element 0" behavior was
    # deviation D2 of the 2026-08-17 e2e contract).
    it 'handles array input with one entry per element (N -> N)' do
      allow(Legion::LLM).to receive(:embed_batch).and_return(
        [{ vector: [0.1, 0.2, 0.3] }, { vector: [0.4, 0.5, 0.6] }]
      )
      post '/v1/embeddings',
           Legion::JSON.dump({ input: %w[Hello world], model: 'legionio' }),
           'CONTENT_TYPE' => 'application/json'
      expect(last_response.status).to eq(200)
      expect(Legion::LLM).to have_received(:embed_batch).with(%w[Hello world], model: 'legionio')
      body = Legion::JSON.load(last_response.body)
      expect(body[:data].map { |e| e[:index] }).to eq([0, 1])
      expect(body[:data].map { |e| e[:embedding] }).to eq([[0.1, 0.2, 0.3], [0.4, 0.5, 0.6]])
    end
  end
end
