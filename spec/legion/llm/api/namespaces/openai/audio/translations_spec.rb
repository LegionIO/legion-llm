# frozen_string_literal: true

require 'spec_helper'
require 'rack/test'
require 'sinatra/base'
require 'sinatra/namespace'
require 'legion/llm/api/namespaces/helpers'
require 'legion/llm/api/namespaces/openai/audio/translations'

RSpec.describe 'Namespaces::OpenAI::Audio::Translations' do
  include Rack::Test::Methods

  let(:app) do
    Class.new(Sinatra::Base) do
      set :host_authorization, permitted: :any
      register Sinatra::Namespace
      helpers Legion::LLM::API::Namespaces::Helpers
      namespace '/v1/audio' do
        register Legion::LLM::API::Namespaces::OpenAI::Audio::Translations
      end
    end
  end

  before do
    allow(Legion::LLM).to receive(:started?).and_return(true)
  end

  describe 'POST /v1/audio/translations' do
    context 'when no capable provider is registered' do
      before do
        allow(Legion::LLM::Call::Registry).to receive(:all_instances).and_return([])
      end

      it 'returns 501 with capability_not_supported error' do
        post '/v1/audio/translations',
             { model: 'whisper-1', file: 'fake_audio' },
             'CONTENT_TYPE' => 'multipart/form-data'

        expect(last_response.status).to eq(501)
        result = Legion::JSON.load(last_response.body)
        expect(result[:error][:type]).to eq('capability_not_supported')
      end
    end

    context 'when a capable provider is registered' do
      let(:mock_registry_entry) do
        { provider: :openai, capabilities: %i[audio_transcription audio_translation], enabled: true }
      end

      let(:mock_response) do
        double(
          'PipelineResponse',
          message:  { content: 'This is the English translation of the audio.' },
          routing:  { model: 'whisper-1', provider: :openai },
          tokens:   { input: 0, output: 10 },
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

      it 'returns 200 with translated text in json format' do
        post '/v1/audio/translations',
             { model: 'whisper-1', file: 'fake_audio_data' },
             'CONTENT_TYPE' => 'multipart/form-data'

        expect(last_response.status).to eq(200)
        result = Legion::JSON.load(last_response.body)
        expect(result[:text]).to be_a(String)
        expect(result[:text]).not_to be_empty
      end

      it 'returns plain text when response_format=text' do
        post '/v1/audio/translations',
             { model: 'whisper-1', file: 'fake_audio_data', response_format: 'text' },
             'CONTENT_TYPE' => 'multipart/form-data'

        expect(last_response.status).to eq(200)
        expect(last_response.content_type).to include('text/plain')
      end

      it 'always targets English (no language param accepted)' do
        expect(Legion::LLM::Inference::Request).to receive(:build) do |**kwargs|
          expect(kwargs[:meta][:task]).to eq(:audio_translation)
          expect(kwargs[:meta][:target_language]).to eq('en')
          Legion::LLM::Inference::Request.build(**kwargs)
        end.and_call_original

        post '/v1/audio/translations',
             { model: 'whisper-1', file: 'fake_audio_data', language: 'fr' },
             'CONTENT_TYPE' => 'multipart/form-data'
      end

      it 'requires model field' do
        post '/v1/audio/translations',
             { file: 'fake_audio' },
             'CONTENT_TYPE' => 'multipart/form-data'

        expect(last_response.status).to eq(400)
        result = Legion::JSON.load(last_response.body)
        expect(result[:error][:message]).to include('model')
      end

      it 'requires file field' do
        post '/v1/audio/translations',
             { model: 'whisper-1' },
             'CONTENT_TYPE' => 'multipart/form-data'

        expect(last_response.status).to eq(400)
        result = Legion::JSON.load(last_response.body)
        expect(result[:error][:message]).to include('file')
      end

      it 'rejects invalid response_format' do
        post '/v1/audio/translations',
             { model: 'whisper-1', file: 'fake', response_format: 'xml' },
             'CONTENT_TYPE' => 'multipart/form-data'

        expect(last_response.status).to eq(400)
        result = Legion::JSON.load(last_response.body)
        expect(result[:error][:message]).to include('response_format')
      end
    end

    it 'returns 503 when LLM not started' do
      allow(Legion::LLM).to receive(:started?).and_return(false)
      post '/v1/audio/translations',
           { model: 'whisper-1', file: 'fake' },
           'CONTENT_TYPE' => 'multipart/form-data'

      expect(last_response.status).to eq(503)
    end
  end
end
