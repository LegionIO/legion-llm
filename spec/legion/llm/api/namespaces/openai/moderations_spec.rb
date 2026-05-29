# frozen_string_literal: true

require 'spec_helper'
require 'rack/test'
require 'sinatra/base'
require 'sinatra/namespace'
require 'legion/llm/api/namespaces/helpers'

RSpec.describe 'Namespaces::OpenAI::Moderations' do
  include Rack::Test::Methods

  before { require 'legion/llm/api/namespaces/openai/moderations' }

  let(:app) do
    Class.new(Sinatra::Base) do
      set :host_authorization, permitted: :any
      register Sinatra::Namespace
      helpers Legion::Logging::Helper
      helpers Legion::LLM::API::Namespaces::Helpers
      register Legion::LLM::API::Namespaces::OpenAI::Moderations
    end
  end

  let(:safe_response_text) do
    'MODERATION_RESULT: safe. Categories: hate=false(0.0001), hate/threatening=false(0.0001), ' \
      'harassment=false(0.0002), harassment/threatening=false(0.0001), self-harm=false(0.0001), ' \
      'self-harm/intent=false(0.0001), self-harm/instructions=false(0.0001), sexual=false(0.0003), ' \
      'sexual/minors=false(0.0001), violence=false(0.0002), violence/graphic=false(0.0001)'
  end

  let(:flagged_response_text) do
    'MODERATION_RESULT: flagged. Categories: hate=true(0.9800), hate/threatening=false(0.0500), ' \
      'harassment=true(0.8700), harassment/threatening=false(0.0400), self-harm=false(0.0001), ' \
      'self-harm/intent=false(0.0001), self-harm/instructions=false(0.0001), sexual=false(0.0001), ' \
      'sexual/minors=false(0.0001), violence=false(0.0002), violence/graphic=false(0.0001)'
  end

  let(:mock_safe_response) do
    double('Response',
           message: { content: safe_response_text },
           routing: { model: 'text-moderation-latest', provider: :openai },
           tokens:  { input: 50, output: 30 },
           tools:   nil,
           stop:    { reason: 'end_turn' })
  end

  let(:mock_flagged_response) do
    double('Response',
           message: { content: flagged_response_text },
           routing: { model: 'text-moderation-latest', provider: :openai },
           tokens:  { input: 50, output: 30 },
           tools:   nil,
           stop:    { reason: 'end_turn' })
  end

  before do
    allow(Legion::LLM).to receive(:started?).and_return(true)
    allow(Legion::LLM::Call::Registry).to receive(:providers).and_return(
      { anthropic: { capabilities: %i[chat moderation] } }
    )
    allow(Legion::LLM::Inference::Request).to receive(:build).and_return(double('Request'))
  end

  describe 'POST /v1/moderations' do
    context 'with a safe string input' do
      before do
        mock_executor = double('Executor')
        allow(Legion::LLM::Inference::Executor).to receive(:new).and_return(mock_executor)
        allow(mock_executor).to receive(:call).and_return(mock_safe_response)
      end

      it 'returns 200 with OpenAI moderations format' do
        post '/v1/moderations',
             Legion::JSON.dump({ input: 'Hello, how are you today?' }),
             'CONTENT_TYPE' => 'application/json'
        expect(last_response.status).to eq(200)
      end

      it 'returns id prefixed with modr-' do
        post '/v1/moderations',
             Legion::JSON.dump({ input: 'Hello' }),
             'CONTENT_TYPE' => 'application/json'
        body = Legion::JSON.load(last_response.body)
        expect(body[:id]).to start_with('modr-')
      end

      it 'returns model field' do
        post '/v1/moderations',
             Legion::JSON.dump({ input: 'Hello' }),
             'CONTENT_TYPE' => 'application/json'
        body = Legion::JSON.load(last_response.body)
        expect(body[:model]).to be_a(String)
        expect(body[:model]).not_to be_empty
      end

      it 'returns results array with one entry per input string' do
        post '/v1/moderations',
             Legion::JSON.dump({ input: 'Hello' }),
             'CONTENT_TYPE' => 'application/json'
        body = Legion::JSON.load(last_response.body)
        expect(body[:results]).to be_an(Array)
        expect(body[:results].size).to eq(1)
      end

      it 'returns flagged=false for safe content' do
        post '/v1/moderations',
             Legion::JSON.dump({ input: 'Hello, how are you today?' }),
             'CONTENT_TYPE' => 'application/json'
        body = Legion::JSON.load(last_response.body)
        result = body[:results].first
        expect(result[:flagged]).to be false
      end

      it 'returns categories hash with all 11 category keys' do
        post '/v1/moderations',
             Legion::JSON.dump({ input: 'Hello' }),
             'CONTENT_TYPE' => 'application/json'
        body = Legion::JSON.load(last_response.body)
        cats = body[:results].first[:categories]
        expect(cats).to have_key(:hate)
        expect(cats).to have_key(:'hate/threatening')
        expect(cats).to have_key(:harassment)
        expect(cats).to have_key(:'harassment/threatening')
        expect(cats).to have_key(:'self-harm')
        expect(cats).to have_key(:'self-harm/intent')
        expect(cats).to have_key(:'self-harm/instructions')
        expect(cats).to have_key(:sexual)
        expect(cats).to have_key(:'sexual/minors')
        expect(cats).to have_key(:violence)
        expect(cats).to have_key(:'violence/graphic')
      end

      it 'returns category_scores hash with float values' do
        post '/v1/moderations',
             Legion::JSON.dump({ input: 'Hello' }),
             'CONTENT_TYPE' => 'application/json'
        body = Legion::JSON.load(last_response.body)
        scores = body[:results].first[:category_scores]
        expect(scores).to be_a(Hash)
        scores.each_value { |v| expect(v).to be_a(Float) }
      end

      it 'returns all category_score values between 0.0 and 1.0' do
        post '/v1/moderations',
             Legion::JSON.dump({ input: 'Hello' }),
             'CONTENT_TYPE' => 'application/json'
        body = Legion::JSON.load(last_response.body)
        scores = body[:results].first[:category_scores]
        scores.each_value { |v| expect(v).to be_between(0.0, 1.0) }
      end

      it 'sets application/json content-type' do
        post '/v1/moderations',
             Legion::JSON.dump({ input: 'Hello' }),
             'CONTENT_TYPE' => 'application/json'
        expect(last_response.content_type).to include('application/json')
      end
    end

    context 'with an array input' do
      before do
        mock_executor = double('Executor')
        allow(Legion::LLM::Inference::Executor).to receive(:new).and_return(mock_executor)
        allow(mock_executor).to receive(:call).and_return(mock_safe_response)
      end

      it 'returns one result per input element' do
        post '/v1/moderations',
             Legion::JSON.dump({ input: %w[Hello World] }),
             'CONTENT_TYPE' => 'application/json'
        expect(last_response.status).to eq(200)
        body = Legion::JSON.load(last_response.body)
        expect(body[:results].size).to eq(2)
      end

      it 'accepts an array of strings' do
        post '/v1/moderations',
             Legion::JSON.dump({ input: ['safe text', 'more safe text'] }),
             'CONTENT_TYPE' => 'application/json'
        expect(last_response.status).to eq(200)
      end
    end

    context 'with flagged content' do
      before do
        mock_executor = double('Executor')
        allow(Legion::LLM::Inference::Executor).to receive(:new).and_return(mock_executor)
        allow(mock_executor).to receive(:call).and_return(mock_flagged_response)
      end

      it 'returns flagged=true when model detects harmful content' do
        post '/v1/moderations',
             Legion::JSON.dump({ input: 'some flagged content' }),
             'CONTENT_TYPE' => 'application/json'
        body = Legion::JSON.load(last_response.body)
        result = body[:results].first
        expect(result[:flagged]).to be true
      end

      it 'returns true for flagged categories' do
        post '/v1/moderations',
             Legion::JSON.dump({ input: 'some flagged content' }),
             'CONTENT_TYPE' => 'application/json'
        body = Legion::JSON.load(last_response.body)
        cats = body[:results].first[:categories]
        expect(cats[:hate]).to be true
        expect(cats[:harassment]).to be true
      end

      it 'returns high scores for flagged categories' do
        post '/v1/moderations',
             Legion::JSON.dump({ input: 'some flagged content' }),
             'CONTENT_TYPE' => 'application/json'
        body = Legion::JSON.load(last_response.body)
        scores = body[:results].first[:category_scores]
        expect(scores[:hate]).to be > 0.5
      end
    end

    context 'with an optional model parameter' do
      before do
        mock_executor = double('Executor')
        allow(Legion::LLM::Inference::Executor).to receive(:new).and_return(mock_executor)
        allow(mock_executor).to receive(:call).and_return(mock_safe_response)
      end

      it 'accepts and uses a model parameter' do
        post '/v1/moderations',
             Legion::JSON.dump({ input: 'Hello', model: 'text-moderation-stable' }),
             'CONTENT_TYPE' => 'application/json'
        expect(last_response.status).to eq(200)
        body = Legion::JSON.load(last_response.body)
        expect(body[:model]).to eq('text-moderation-stable')
      end
    end

    context 'with missing input' do
      it 'returns 400 when input is missing' do
        post '/v1/moderations',
             Legion::JSON.dump({}),
             'CONTENT_TYPE' => 'application/json'
        expect(last_response.status).to eq(400)
        body = Legion::JSON.load(last_response.body)
        expect(body[:error][:type]).to eq('invalid_request_error')
        expect(body[:error][:message]).to match(/input/)
      end

      it 'returns 400 when input is empty string' do
        post '/v1/moderations',
             Legion::JSON.dump({ input: '' }),
             'CONTENT_TYPE' => 'application/json'
        expect(last_response.status).to eq(400)
        body = Legion::JSON.load(last_response.body)
        expect(body[:error][:type]).to eq('invalid_request_error')
      end

      it 'returns 400 when input is an empty array' do
        post '/v1/moderations',
             Legion::JSON.dump({ input: [] }),
             'CONTENT_TYPE' => 'application/json'
        expect(last_response.status).to eq(400)
        body = Legion::JSON.load(last_response.body)
        expect(body[:error][:type]).to eq('invalid_request_error')
      end
    end

    context 'when input array exceeds MAX_MODERATION_INPUTS' do
      before do
        mock_executor = double('Executor')
        allow(Legion::LLM::Inference::Executor).to receive(:new).and_return(mock_executor)
        allow(mock_executor).to receive(:call).and_return(mock_safe_response)
      end

      it 'returns 400 when more than 32 inputs provided' do
        post '/v1/moderations',
             Legion::JSON.dump({ input: Array.new(33, 'text') }),
             'CONTENT_TYPE' => 'application/json'
        expect(last_response.status).to eq(400)
        body = Legion::JSON.load(last_response.body)
        expect(body[:error][:type]).to eq('invalid_request_error')
        expect(body[:error][:code]).to eq('too_many_inputs')
      end
    end

    context 'when no provider supports moderation or chat capability' do
      before do
        allow(Legion::LLM::Call::Registry).to receive(:providers).and_return({})
      end

      it 'returns 501 with capability_unavailable code' do
        post '/v1/moderations',
             Legion::JSON.dump({ input: 'Hello' }),
             'CONTENT_TYPE' => 'application/json'
        expect(last_response.status).to eq(501)
        body = Legion::JSON.load(last_response.body)
        expect(body[:error][:code]).to eq('capability_unavailable')
      end
    end

    context 'when LLM is not started' do
      before { allow(Legion::LLM).to receive(:started?).and_return(false) }

      it 'returns 503' do
        post '/v1/moderations',
             Legion::JSON.dump({ input: 'Hello' }),
             'CONTENT_TYPE' => 'application/json'
        expect(last_response.status).to eq(503)
      end
    end

    context 'when provider raises AuthError' do
      before do
        mock_executor = double('Executor')
        allow(Legion::LLM::Inference::Executor).to receive(:new).and_return(mock_executor)
        allow(mock_executor).to receive(:call).and_raise(Legion::LLM::AuthError, 'invalid key')
      end

      it 'returns 401 with OpenAI error format' do
        post '/v1/moderations',
             Legion::JSON.dump({ input: 'Hello' }),
             'CONTENT_TYPE' => 'application/json'
        expect(last_response.status).to eq(401)
        body = Legion::JSON.load(last_response.body)
        expect(body[:error][:type]).to eq('authentication_error')
      end
    end

    context 'when provider raises RateLimitError' do
      before do
        mock_executor = double('Executor')
        allow(Legion::LLM::Inference::Executor).to receive(:new).and_return(mock_executor)
        allow(mock_executor).to receive(:call).and_raise(Legion::LLM::RateLimitError, 'too many requests')
      end

      it 'returns 429 with OpenAI error format' do
        post '/v1/moderations',
             Legion::JSON.dump({ input: 'Hello' }),
             'CONTENT_TYPE' => 'application/json'
        expect(last_response.status).to eq(429)
        body = Legion::JSON.load(last_response.body)
        expect(body[:error][:type]).to eq('rate_limit_error')
        expect(body[:error][:code]).to eq('rate_limit_exceeded')
      end
    end

    context 'when provider raises ProviderDown' do
      before do
        mock_executor = double('Executor')
        allow(Legion::LLM::Inference::Executor).to receive(:new).and_return(mock_executor)
        allow(mock_executor).to receive(:call).and_raise(Legion::LLM::ProviderDown, 'provider offline')
      end

      it 'returns 502 with OpenAI error format' do
        post '/v1/moderations',
             Legion::JSON.dump({ input: 'Hello' }),
             'CONTENT_TYPE' => 'application/json'
        expect(last_response.status).to eq(502)
        body = Legion::JSON.load(last_response.body)
        expect(body[:error][:type]).to eq('server_error')
      end
    end

    context 'when an unexpected error occurs' do
      before do
        mock_executor = double('Executor')
        allow(Legion::LLM::Inference::Executor).to receive(:new).and_return(mock_executor)
        allow(mock_executor).to receive(:call).and_raise(Legion::LLM::InferenceError, 'something went wrong')
      end

      it 'returns 500 with OpenAI error format' do
        post '/v1/moderations',
             Legion::JSON.dump({ input: 'Hello' }),
             'CONTENT_TYPE' => 'application/json'
        expect(last_response.status).to eq(500)
        body = Legion::JSON.load(last_response.body)
        expect(body[:error][:type]).to eq('server_error')
      end
    end
  end

  describe '.build_moderation_prompt' do
    it 'returns a system prompt string' do
      result = Legion::LLM::API::Namespaces::OpenAI::Moderations.build_moderation_prompt
      expect(result).to be_a(String)
      expect(result).not_to be_empty
    end

    it 'includes all 11 category names' do
      result = Legion::LLM::API::Namespaces::OpenAI::Moderations.build_moderation_prompt
      expect(result).to include('hate')
      expect(result).to include('harassment')
      expect(result).to include('self-harm')
      expect(result).to include('sexual')
      expect(result).to include('violence')
    end

    it 'includes the MODERATION_RESULT output format instruction' do
      result = Legion::LLM::API::Namespaces::OpenAI::Moderations.build_moderation_prompt
      expect(result).to include('MODERATION_RESULT')
    end
  end

  describe '.parse_moderation_response' do
    it 'parses a safe structured response' do
      text = 'MODERATION_RESULT: safe. Categories: hate=false(0.0001), hate/threatening=false(0.0001), ' \
             'harassment=false(0.0002), harassment/threatening=false(0.0001), self-harm=false(0.0001), ' \
             'self-harm/intent=false(0.0001), self-harm/instructions=false(0.0001), sexual=false(0.0003), ' \
             'sexual/minors=false(0.0001), violence=false(0.0002), violence/graphic=false(0.0001)'
      result = Legion::LLM::API::Namespaces::OpenAI::Moderations.parse_moderation_response(text)
      expect(result[:flagged]).to be false
      expect(result[:categories][:hate]).to be false
      expect(result[:category_scores][:hate]).to eq(0.0001)
    end

    it 'parses a flagged structured response' do
      text = 'MODERATION_RESULT: flagged. Categories: hate=true(0.9500), hate/threatening=false(0.0400), ' \
             'harassment=true(0.8200), harassment/threatening=false(0.0300), self-harm=false(0.0001), ' \
             'self-harm/intent=false(0.0001), self-harm/instructions=false(0.0001), sexual=false(0.0001), ' \
             'sexual/minors=false(0.0001), violence=false(0.0002), violence/graphic=false(0.0001)'
      result = Legion::LLM::API::Namespaces::OpenAI::Moderations.parse_moderation_response(text)
      expect(result[:flagged]).to be true
      expect(result[:categories][:hate]).to be true
      expect(result[:category_scores][:hate]).to eq(0.9500)
    end

    it 'returns safe defaults when response is unparseable' do
      result = Legion::LLM::API::Namespaces::OpenAI::Moderations.parse_moderation_response('I cannot assess this.')
      expect(result[:flagged]).to be false
      expect(result[:categories]).to be_a(Hash)
      expect(result[:category_scores]).to be_a(Hash)
      result[:category_scores].each_value { |v| expect(v).to be_a(Float) }
    end

    it 'returns all 11 category keys even on fallback' do
      result = Legion::LLM::API::Namespaces::OpenAI::Moderations.parse_moderation_response('')
      expect(result[:categories].keys.size).to eq(11)
      expect(result[:category_scores].keys.size).to eq(11)
    end
  end
end
