# frozen_string_literal: true

require 'spec_helper'

begin
  require 'sinatra/base'
rescue LoadError
  nil
end

if defined?(Sinatra::Base) && defined?(Legion::LLM::Routes)
  RSpec.describe 'LLM API route surface' do
    let(:test_app) do
      Class.new(Sinatra::Base) do
        set :show_exceptions, false
        set :raise_errors, false
        set :host_authorization, permitted: :any

        register Legion::LLM::Routes
      end
    end

    let(:expected_routes) do
      {
        'POST' => [
          '/api/llm/chat',
          '/api/llm/inference',
          '/v1/chat/completions',
          '/v1/embeddings',
          '/v1/messages'
        ],
        'GET'  => [
          '/api/llm/providers',
          '/api/llm/providers/:name',
          '/api/llm/providers/:name/models',
          '/api/llm/models',
          '/api/llm/models/:id',
          '/api/llm/offerings',
          '/api/llm/offerings/:id',
          '/api/llm/instances',
          '/api/llm/instances/:id',
          '/api/llm/routing',
          '/v1/models',
          '/v1/models/:id'
        ]
      }
    end

    it 'uses legion-llm routes as the official API owner' do
      expect(Legion::LLM::Routes).to equal(Legion::LLM::API)
    end

    it 'registers every native and compatibility endpoint from legion-llm' do
      expected_routes.each do |verb, paths|
        registered = test_app.routes.fetch(verb).map { |route| route.first.to_s }
        expect(registered).to include(*paths)
      end
    end
  end
end
