# frozen_string_literal: true

require 'spec_helper'
require 'rack/test'
require 'sinatra/base'
require 'sinatra/namespace'
require 'legion/llm/api/namespaces/helpers'

RSpec.describe 'Namespaces::OpenAI::Completions' do
  include Rack::Test::Methods

  before { require 'legion/llm/api/namespaces/openai/completions' }

  let(:pipeline_response) do
    double('Response',
           routing: { model: 'legionio' },
           tokens:  { input_tokens: 8, output_tokens: 15 },
           message: { content: 'The answer is 42.' },
           tools:   [],
           stop:    { reason: 'stop' })
  end

  let(:app) do
    Class.new(Sinatra::Base) do
      set :host_authorization, permitted: :any
      register Sinatra::Namespace
      helpers Legion::Logging::Helper
      helpers Legion::LLM::API::Namespaces::Helpers
      register Legion::LLM::API::Namespaces::OpenAI::Completions
    end
  end

  before do
    allow(Legion::LLM).to receive(:started?).and_return(true)
    allow(Legion::LLM::Inference::Request).to receive(:build).and_return(double('Request'))
    allow(Legion::LLM::Inference::Executor).to receive(:new).and_return(
      double('Executor', call: pipeline_response)
    )
    Legion::Settings[:llm][:default_model] = 'legionio'
  end

  describe 'POST /v1/completions' do
    it 'returns 400 when prompt is missing' do
      post '/v1/completions', Legion::JSON.dump({ model: 'legionio' }), 'CONTENT_TYPE' => 'application/json'
      expect(last_response.status).to eq(400)
      body = Legion::JSON.load(last_response.body)
      expect(body[:error][:type]).to eq('invalid_request_error')
    end

    it 'returns legacy text_completion format' do
      post '/v1/completions',
           Legion::JSON.dump({ prompt: 'What is the meaning of life?', model: 'legionio' }),
           'CONTENT_TYPE' => 'application/json'
      expect(last_response.status).to eq(200)
      body = Legion::JSON.load(last_response.body)
      expect(body[:object]).to eq('text_completion')
      expect(body[:choices]).to be_an(Array)
      expect(body[:choices].first[:text]).to eq('The answer is 42.')
      expect(body[:choices].first[:index]).to eq(0)
      expect(body[:usage][:prompt_tokens]).to be_a(Integer)
    end
  end
end
