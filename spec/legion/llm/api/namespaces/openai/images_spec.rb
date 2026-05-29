# frozen_string_literal: true

require 'spec_helper'
require 'rack/test'
require 'sinatra/base'
require 'sinatra/namespace'
require 'legion/llm/api/namespaces/helpers'
require 'legion/llm/api/namespaces/openai/images'

RSpec.describe 'Namespaces::OpenAI::Images' do
  include Rack::Test::Methods

  let(:app) do
    Class.new(Sinatra::Base) do
      set :host_authorization, permitted: :any
      register Sinatra::Namespace
      helpers Legion::LLM::API::Namespaces::Helpers
      namespace '/v1/images' do
        register Legion::LLM::API::Namespaces::OpenAI::Images
      end
    end
  end

  before do
    allow(Legion::LLM).to receive(:started?).and_return(true)
  end

  # ─── POST /v1/images/generations ───────────────────────────────────────────

  describe 'POST /v1/images/generations' do
    context 'when no capable provider is registered' do
      before do
        allow(Legion::LLM::Call::Registry).to receive(:all_instances).and_return([])
      end

      it 'returns 501 with capability_not_supported error' do
        post '/v1/images/generations',
             Legion::JSON.dump({ prompt: 'a white siamese cat', n: 1, size: '1024x1024' }),
             'CONTENT_TYPE' => 'application/json'

        expect(last_response.status).to eq(501)
        result = Legion::JSON.load(last_response.body)
        expect(result[:error][:type]).to eq('capability_not_supported')
      end
    end

    context 'when a capable provider is registered' do
      let(:mock_registry_entry) do
        { provider: :openai, capabilities: %i[chat_completion image_generation], enabled: true }
      end

      let(:mock_response) do
        double(
          'PipelineResponse',
          message:  { content: nil, images: [{ b64_json: Base64.strict_encode64('fake_image_data') }] },
          routing:  { model: 'dall-e-3', provider: :openai },
          tokens:   { input: 5, output: 0 },
          tools:    nil,
          stop:     { reason: 'stop' }
        )
      end

      before do
        allow(Legion::LLM::Call::Registry).to receive(:all_instances).and_return([mock_registry_entry])
        mock_executor = instance_double(Legion::LLM::Inference::Executor)
        allow(Legion::LLM::Inference::Executor).to receive(:new).and_return(mock_executor)
        allow(mock_executor).to receive(:call).and_return(mock_response)
      end

      it 'returns 200 with OpenAI images response shape' do
        post '/v1/images/generations',
             Legion::JSON.dump({ prompt: 'a white siamese cat', n: 1, size: '1024x1024', model: 'dall-e-3' }),
             'CONTENT_TYPE' => 'application/json'

        expect(last_response.status).to eq(200)
        result = Legion::JSON.load(last_response.body)
        expect(result[:created]).to be_a(Integer)
        expect(result[:data]).to be_an(Array)
        expect(result[:data].first).to have_key(:b64_json).or have_key(:url)
      end

      it 'requires prompt field' do
        post '/v1/images/generations',
             Legion::JSON.dump({ n: 1, size: '1024x1024' }),
             'CONTENT_TYPE' => 'application/json'

        expect(last_response.status).to eq(400)
        result = Legion::JSON.load(last_response.body)
        expect(result[:error][:type]).to eq('invalid_request_error')
        expect(result[:error][:message]).to include('prompt')
      end

      it 'passes prompt, model, n, size to inference request' do
        expect(Legion::LLM::Inference::Request).to receive(:build) do |**kwargs|
          expect(kwargs[:routing][:model]).to eq('dall-e-3')
          expect(kwargs[:meta][:prompt]).to eq('a white siamese cat')
          expect(kwargs[:meta][:n]).to eq(1)
          expect(kwargs[:meta][:size]).to eq('1024x1024')
          Legion::LLM::Inference::Request.build(**kwargs)
        end.and_call_original

        post '/v1/images/generations',
             Legion::JSON.dump({ prompt: 'a white siamese cat', n: 1, size: '1024x1024', model: 'dall-e-3' }),
             'CONTENT_TYPE' => 'application/json'
      end
    end

    it 'returns 503 when LLM not started' do
      allow(Legion::LLM).to receive(:started?).and_return(false)
      post '/v1/images/generations',
           Legion::JSON.dump({ prompt: 'a cat' }),
           'CONTENT_TYPE' => 'application/json'

      expect(last_response.status).to eq(503)
    end
  end

  # ─── POST /v1/images/edits ─────────────────────────────────────────────────

  describe 'POST /v1/images/edits' do
    context 'when no capable provider is registered' do
      before do
        allow(Legion::LLM::Call::Registry).to receive(:all_instances).and_return([])
      end

      it 'returns 501 with capability_not_supported error' do
        post '/v1/images/edits',
             Legion::JSON.dump({ prompt: 'add a hat', image: 'base64data' }),
             'CONTENT_TYPE' => 'application/json'

        expect(last_response.status).to eq(501)
        result = Legion::JSON.load(last_response.body)
        expect(result[:error][:type]).to eq('capability_not_supported')
      end
    end

    context 'when a capable provider is registered' do
      let(:mock_registry_entry) do
        { provider: :openai, capabilities: %i[chat_completion image_generation image_editing], enabled: true }
      end

      let(:mock_response) do
        double(
          'PipelineResponse',
          message:  { content: nil, images: [{ b64_json: Base64.strict_encode64('edited_image') }] },
          routing:  { model: 'dall-e-2', provider: :openai },
          tokens:   { input: 5, output: 0 },
          tools:    nil,
          stop:     { reason: 'stop' }
        )
      end

      before do
        allow(Legion::LLM::Call::Registry).to receive(:all_instances).and_return([mock_registry_entry])
        mock_executor = instance_double(Legion::LLM::Inference::Executor)
        allow(Legion::LLM::Inference::Executor).to receive(:new).and_return(mock_executor)
        allow(mock_executor).to receive(:call).and_return(mock_response)
      end

      it 'returns 200 with images array' do
        post '/v1/images/edits',
             Legion::JSON.dump({ prompt: 'add a hat', image: Base64.strict_encode64('fake_png') }),
             'CONTENT_TYPE' => 'application/json'

        expect(last_response.status).to eq(200)
        result = Legion::JSON.load(last_response.body)
        expect(result[:data]).to be_an(Array)
      end

      it 'requires prompt field' do
        post '/v1/images/edits',
             Legion::JSON.dump({ image: Base64.strict_encode64('fake_png') }),
             'CONTENT_TYPE' => 'application/json'

        expect(last_response.status).to eq(400)
        result = Legion::JSON.load(last_response.body)
        expect(result[:error][:message]).to include('prompt')
      end

      it 'accepts multipart/form-data with file upload' do
        post '/v1/images/edits',
             { prompt: 'add a hat', image: 'base64encodeddata' },
             'CONTENT_TYPE' => 'multipart/form-data'

        # Either 200 or 400 is acceptable; what must NOT happen is a 500
        expect([200, 400]).to include(last_response.status)
        expect(last_response.status).not_to eq(500)
      end
    end
  end

  # ─── POST /v1/images/variations ────────────────────────────────────────────

  describe 'POST /v1/images/variations' do
    context 'when no capable provider is registered' do
      before do
        allow(Legion::LLM::Call::Registry).to receive(:all_instances).and_return([])
      end

      it 'returns 501 with capability_not_supported error' do
        post '/v1/images/variations',
             Legion::JSON.dump({ image: 'base64data' }),
             'CONTENT_TYPE' => 'application/json'

        expect(last_response.status).to eq(501)
        result = Legion::JSON.load(last_response.body)
        expect(result[:error][:type]).to eq('capability_not_supported')
      end
    end

    context 'when a capable provider is registered' do
      let(:mock_registry_entry) do
        { provider: :openai, capabilities: %i[image_generation image_variation], enabled: true }
      end

      let(:mock_response) do
        double(
          'PipelineResponse',
          message:  { content: nil, images: [{ b64_json: Base64.strict_encode64('variation') }] },
          routing:  { model: 'dall-e-2', provider: :openai },
          tokens:   { input: 0, output: 0 },
          tools:    nil,
          stop:     { reason: 'stop' }
        )
      end

      before do
        allow(Legion::LLM::Call::Registry).to receive(:all_instances).and_return([mock_registry_entry])
        mock_executor = instance_double(Legion::LLM::Inference::Executor)
        allow(Legion::LLM::Inference::Executor).to receive(:new).and_return(mock_executor)
        allow(mock_executor).to receive(:call).and_return(mock_response)
      end

      it 'returns 200 with images array' do
        post '/v1/images/variations',
             Legion::JSON.dump({ image: Base64.strict_encode64('source_image'), n: 2, size: '512x512' }),
             'CONTENT_TYPE' => 'application/json'

        expect(last_response.status).to eq(200)
        result = Legion::JSON.load(last_response.body)
        expect(result[:data]).to be_an(Array)
      end

      it 'requires image field' do
        post '/v1/images/variations',
             Legion::JSON.dump({ n: 1 }),
             'CONTENT_TYPE' => 'application/json'

        expect(last_response.status).to eq(400)
        result = Legion::JSON.load(last_response.body)
        expect(result[:error][:message]).to include('image')
      end
    end
  end
end
