# frozen_string_literal: true

require 'spec_helper'
require 'rack/test'
require 'sinatra/base'
require 'sinatra/namespace'
require 'legion/llm/api/namespaces/helpers'
require 'legion/llm/api/namespaces/openai/audio/speech'

RSpec.describe 'Namespaces::OpenAI::Audio::Speech' do
  include Rack::Test::Methods

  let(:app) do
    Class.new(Sinatra::Base) do
      set :host_authorization, permitted: :any
      register Sinatra::Namespace
      helpers Legion::LLM::API::Namespaces::Helpers
      namespace '/v1/audio' do
        register Legion::LLM::API::Namespaces::OpenAI::Audio::Speech
      end
    end
  end

  before do
    allow(Legion::LLM).to receive(:started?).and_return(true)
  end

  describe 'POST /v1/audio/speech' do
    let(:valid_body) do
      { model: 'tts-1', input: 'Hello, this is a test.', voice: 'alloy' }
    end

    context 'when no capable provider is registered' do
      before do
        allow(Legion::LLM::Call::Registry).to receive(:all_instances).and_return([])
      end

      it 'returns 501 with capability_not_supported error' do
        post '/v1/audio/speech',
             Legion::JSON.dump(valid_body),
             'CONTENT_TYPE' => 'application/json'

        expect(last_response.status).to eq(501)
        result = Legion::JSON.load(last_response.body)
        expect(result[:error][:type]).to eq('capability_not_supported')
      end
    end

    context 'when a capable provider is registered' do
      let(:fake_audio_bytes) { "\xFF\xFB\x90\x00" * 100 } # fake mp3 frame header pattern

      let(:mock_registry_entry) do
        { provider: :openai, capabilities: %i[text_to_speech audio_speech], enabled: true }
      end

      let(:mock_response) do
        double(
          'PipelineResponse',
          message: { content: nil, audio_binary: fake_audio_bytes, audio_format: 'mp3' },
          routing: { model: 'tts-1', provider: :openai },
          tokens:  { input: 5, output: 0 },
          tools:   nil,
          stop:    { reason: 'stop' }
        )
      end

      before do
        allow(Legion::LLM::Call::Registry).to receive(:all_instances).and_return([mock_registry_entry])
        mock_executor = instance_double(Legion::LLM::Inference::Executor)
        allow(Legion::LLM::Inference::Executor).to receive(:new).and_return(mock_executor)
        allow(mock_executor).to receive(:call).and_return(mock_response)
      end

      it 'returns 200 with audio/mpeg content-type for mp3' do
        post '/v1/audio/speech',
             Legion::JSON.dump(valid_body),
             'CONTENT_TYPE' => 'application/json'

        expect(last_response.status).to eq(200)
        expect(last_response.content_type).to include('audio/mpeg')
        expect(last_response.body.length).to be > 0
      end

      it 'returns correct Content-Type for opus format' do
        allow(mock_response).to receive(:message).and_return(
          { content: nil, audio_binary: fake_audio_bytes, audio_format: 'opus' }
        )
        post '/v1/audio/speech',
             Legion::JSON.dump(valid_body.merge(response_format: 'opus')),
             'CONTENT_TYPE' => 'application/json'

        expect(last_response.status).to eq(200)
        expect(last_response.content_type).to include('audio/opus')
      end

      it 'returns correct Content-Type for wav format' do
        allow(mock_response).to receive(:message).and_return(
          { content: nil, audio_binary: fake_audio_bytes, audio_format: 'wav' }
        )
        post '/v1/audio/speech',
             Legion::JSON.dump(valid_body.merge(response_format: 'wav')),
             'CONTENT_TYPE' => 'application/json'

        expect(last_response.status).to eq(200)
        expect(last_response.content_type).to include('audio/wav')
      end

      it 'requires model field' do
        post '/v1/audio/speech',
             Legion::JSON.dump({ input: 'hello', voice: 'alloy' }),
             'CONTENT_TYPE' => 'application/json'

        expect(last_response.status).to eq(400)
        result = Legion::JSON.load(last_response.body)
        expect(result[:error][:message]).to include('model')
      end

      it 'requires input field' do
        post '/v1/audio/speech',
             Legion::JSON.dump({ model: 'tts-1', voice: 'alloy' }),
             'CONTENT_TYPE' => 'application/json'

        expect(last_response.status).to eq(400)
        result = Legion::JSON.load(last_response.body)
        expect(result[:error][:message]).to include('input')
      end

      it 'requires voice field' do
        post '/v1/audio/speech',
             Legion::JSON.dump({ model: 'tts-1', input: 'hello' }),
             'CONTENT_TYPE' => 'application/json'

        expect(last_response.status).to eq(400)
        result = Legion::JSON.load(last_response.body)
        expect(result[:error][:message]).to include('voice')
      end

      it 'rejects invalid voice value' do
        post '/v1/audio/speech',
             Legion::JSON.dump({ model: 'tts-1', input: 'hello', voice: 'invalid_voice' }),
             'CONTENT_TYPE' => 'application/json'

        expect(last_response.status).to eq(400)
        result = Legion::JSON.load(last_response.body)
        expect(result[:error][:message]).to include('voice')
      end

      it 'rejects invalid response_format' do
        post '/v1/audio/speech',
             Legion::JSON.dump(valid_body.merge(response_format: 'xml')),
             'CONTENT_TYPE' => 'application/json'

        expect(last_response.status).to eq(400)
        result = Legion::JSON.load(last_response.body)
        expect(result[:error][:message]).to include('response_format')
      end

      it 'passes voice, speed, and format to inference meta' do
        expect(Legion::LLM::Inference::Request).to receive(:build).and_wrap_original do |original, **kwargs|
          expect(kwargs[:meta][:task]).to eq(:text_to_speech)
          expect(kwargs[:meta][:voice]).to eq('nova')
          expect(kwargs[:meta][:speed]).to eq(1.5)
          expect(kwargs[:meta][:response_format]).to eq('mp3')
          original.call(**kwargs)
        end

        post '/v1/audio/speech',
             Legion::JSON.dump(valid_body.merge(voice: 'nova', speed: 1.5, response_format: 'mp3')),
             'CONTENT_TYPE' => 'application/json'
      end

      it 'falls back to synthesized binary when provider returns text content' do
        text_response = double(
          'PipelineResponse',
          message: { content: 'SYNTHESIZED_AUDIO_PLACEHOLDER', audio_binary: nil, audio_format: nil },
          routing: { model: 'tts-1', provider: :local },
          tokens:  { input: 5, output: 0 },
          tools:   nil,
          stop:    { reason: 'stop' }
        )
        allow(Legion::LLM::Inference::Executor).to receive_message_chain(:new, :call).and_return(text_response)

        post '/v1/audio/speech',
             Legion::JSON.dump(valid_body),
             'CONTENT_TYPE' => 'application/json'

        # Must return audio MIME, not JSON — even in fallback
        expect(last_response.status).to eq(200)
        expect(last_response.content_type).to include('audio/')
      end
    end

    it 'returns 503 when LLM not started' do
      allow(Legion::LLM).to receive(:started?).and_return(false)
      post '/v1/audio/speech',
           Legion::JSON.dump({ model: 'tts-1', input: 'hi', voice: 'alloy' }),
           'CONTENT_TYPE' => 'application/json'

      expect(last_response.status).to eq(503)
    end
  end
end
