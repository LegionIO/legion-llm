# frozen_string_literal: true

require 'spec_helper'
require 'rack/test'
require 'sinatra/base'
require 'sinatra/namespace'
require 'legion/llm/api/namespaces/helpers'
require 'legion/llm/api/namespaces/anthropic/messages'
require 'legion/llm/api/namespaces/openai/responses'
require 'legion/llm/api/namespaces/openai/chat/completions'
require 'legion/llm/api/debug_formats'

RSpec.describe 'API::DebugFormats (G21)' do
  include Rack::Test::Methods

  let(:canonical) { Legion::Extensions::Llm::Canonical }

  let(:app) do
    Class.new(Sinatra::Base) do
      set :host_authorization, permitted: :any
      register Sinatra::Namespace
      helpers Legion::LLM::API::Namespaces::Helpers
      namespace('/v1/messages') { register Legion::LLM::API::Namespaces::Anthropic::Messages }
      register Legion::LLM::API::Namespaces::OpenAI::Responses
      register Legion::LLM::API::Namespaces::OpenAI::Chat::Completions
    end
  end

  let(:mock_response) do
    instance_double(
      Legion::LLM::Inference::Response,
      message:         { content: 'Hello there!' },
      routing:         { model: 'qwen3.6-27b', provider: :vllm },
      tokens:          { input_tokens: 10, output_tokens: 5 },
      thinking:        nil,
      tools:           [],
      stop:            { reason: 'end_turn' },
      timestamps:      {},
      timeline:        [],
      request_id:      'req_test_canon',
      conversation_id: 'conv_canon'
    )
  end

  let(:mock_executor) do
    instance_double(Legion::LLM::Inference::Executor).tap do |ex|
      allow(ex).to receive(:call).and_return(mock_response)
      allow(ex).to receive(:stream_preflight!).and_return(nil)
      allow(ex).to receive(:call_stream).and_yield(
        double(content: 'Hello there!', thinking: nil)
      ).and_return(mock_response)
    end
  end

  before do
    allow(Legion::LLM).to receive(:started?).and_return(true)
    allow(Legion::LLM::Inference::Executor).to receive(:new).and_return(mock_executor)
    Legion::Settings[:llm][:default_model] = 'qwen3.6-27b'
    # Force-enable for tests; the default already returns true in dev/test envs
    # but make it explicit so a deployment-mode shift doesn't break this suite.
    Legion::Settings[:llm][:api][:debug_formats][:enabled] = true
  end

  describe '.enabled?' do
    it 'reflects the settings flag' do
      Legion::Settings[:llm][:api][:debug_formats][:enabled] = false
      expect(Legion::LLM::API::DebugFormats.enabled?).to be(false)

      Legion::Settings[:llm][:api][:debug_formats][:enabled] = true
      expect(Legion::LLM::API::DebugFormats.enabled?).to be(true)
    end
  end

  describe 'gating: when disabled, headers are ignored' do
    before { Legion::Settings[:llm][:api][:debug_formats][:enabled] = false }

    it 'returns the normal Anthropic body even with X-Legion-Format: canonical' do
      post '/v1/messages',
           Legion::JSON.dump({ model: 'claude', messages: [{ role: 'user', content: 'hi' }], max_tokens: 50 }),
           'CONTENT_TYPE'         => 'application/json',
           'HTTP_X_LEGION_FORMAT' => 'canonical'
      body = Legion::JSON.load(last_response.body)
      expect(body[:type]).to eq('message')
      expect(body[:object]).to be_nil
    end

    it 'omits _legion_debug.echo_request even with X-Legion-Debug: echo-request' do
      post '/v1/messages',
           Legion::JSON.dump({ model: 'claude', messages: [{ role: 'user', content: 'hi' }], max_tokens: 50 }),
           'CONTENT_TYPE'        => 'application/json',
           'HTTP_X_LEGION_DEBUG' => 'echo-request'
      body = Legion::JSON.load(last_response.body)
      expect(body[:_legion_debug]).to be_nil
    end
  end

  describe 'X-Legion-Format: canonical (non-streaming)' do
    %w[/v1/messages /v1/responses /v1/chat/completions].each do |path|
      it "returns canonical envelope on #{path}" do
        body = if path == '/v1/responses'
                 { input: 'hi', model: 'qwen3.6-27b' }
               elsif path == '/v1/messages'
                 { model: 'qwen3.6-27b', messages: [{ role: 'user', content: 'hi' }], max_tokens: 50 }
               else
                 { model: 'qwen3.6-27b', messages: [{ role: 'user', content: 'hi' }] }
               end
        post path, Legion::JSON.dump(body),
             'CONTENT_TYPE'         => 'application/json',
             'HTTP_X_LEGION_FORMAT' => 'canonical'

        expect(last_response.status).to eq(200)
        expect(last_response.headers['X-Legion-Contract-Version']).to eq(canonical::CONTRACT_VERSION)
        parsed = Legion::JSON.load(last_response.body)
        expect(parsed[:object]).to eq('canonical.response')
        expect(parsed[:contract_version]).to eq(canonical::CONTRACT_VERSION)
        expect(parsed[:response]).to be_a(Hash)
        expect(parsed[:response][:text]).to eq('Hello there!')
      end
    end
  end

  describe 'X-Legion-Debug: echo-request (non-streaming)' do
    it 'attaches the parsed canonical request to /v1/messages responses' do
      post '/v1/messages',
           Legion::JSON.dump({ model: 'qwen3.6-27b', messages: [{ role: 'user', content: 'hi' }], max_tokens: 50 }),
           'CONTENT_TYPE'        => 'application/json',
           'HTTP_X_LEGION_DEBUG' => 'echo-request'
      body = Legion::JSON.load(last_response.body)
      expect(body[:type]).to eq('message')
      expect(body[:_legion_debug]).to be_a(Hash)
      echo = body[:_legion_debug][:echo_request]
      expect(echo[:messages]).to be_an(Array)
      # role round-trips through Canonical::Message which stores it as a Symbol;
      # JSON renders it as a string.
      expect(echo[:messages].first[:role].to_s).to eq('user')
    end

    it 'attaches the parsed canonical request to /v1/responses responses' do
      post '/v1/responses',
           Legion::JSON.dump({ input: 'hi', model: 'qwen3.6-27b' }),
           'CONTENT_TYPE'        => 'application/json',
           'HTTP_X_LEGION_DEBUG' => 'echo-request'
      body = Legion::JSON.load(last_response.body)
      expect(body[:object]).to eq('response')
      expect(body[:_legion_debug][:echo_request][:messages]).to be_an(Array)
    end

    it 'attaches the parsed canonical request to /v1/chat/completions responses' do
      post '/v1/chat/completions',
           Legion::JSON.dump({ model: 'qwen3.6-27b', messages: [{ role: 'user', content: 'hi' }] }),
           'CONTENT_TYPE'        => 'application/json',
           'HTTP_X_LEGION_DEBUG' => 'echo-request'
      body = Legion::JSON.load(last_response.body)
      expect(body[:object]).to eq('chat.completion')
      expect(body[:_legion_debug][:echo_request][:messages]).to be_an(Array)
    end
  end

  describe 'X-Legion-Format: canonical (streaming)' do
    it 'returns canonical SSE chunks on /v1/messages' do
      post '/v1/messages',
           Legion::JSON.dump({ model: 'qwen3.6-27b', messages: [{ role: 'user', content: 'hi' }], max_tokens: 50, stream: true }),
           'CONTENT_TYPE'         => 'application/json',
           'HTTP_ACCEPT'          => 'text/event-stream',
           'HTTP_X_LEGION_FORMAT' => 'canonical'
      expect(last_response.content_type).to include('text/event-stream')
      expect(last_response.body).to include('"type":"start"')
      expect(last_response.body).to include('"type":"text_delta"')
      expect(last_response.body).to include('data: [DONE]')
      # No client-format markers
      expect(last_response.body).not_to include('event: message_start')
      expect(last_response.body).not_to include('event: content_block_start')
    end
  end

  # The G21 equivalence invariant: same semantic payload sent to /v1/messages
  # and /v1/responses must echo back IDENTICAL Canonical::Request hashes
  # (modulo client-side identity fields like the request id and conversation id
  # which are intentionally generated independently per ingress).
  describe 'EQUIVALENCE INVARIANT — /v1/messages vs /v1/responses' do
    let(:user_text) { 'Translate "hello" to French' }

    let(:anthropic_payload) do
      {
        model:       'qwen3.6-27b',
        messages:    [{ role: 'user', content: user_text }],
        max_tokens:  1024,
        temperature: 0.7
      }
    end

    let(:responses_payload) do
      {
        model:             'qwen3.6-27b',
        input:             [{ role: 'user', content: user_text }],
        max_output_tokens: 1024,
        temperature:       0.7
      }
    end

    def echo_for(path, payload)
      post path, Legion::JSON.dump(payload),
           'CONTENT_TYPE'        => 'application/json',
           'HTTP_X_LEGION_DEBUG' => 'echo-request'
      Legion::JSON.load(last_response.body)[:_legion_debug][:echo_request]
    end

    # Strip per-message identity fields (auto-generated id, timestamp) so the
    # equivalence assertion compares semantic content only — the canonical
    # contract's identity fields are intentionally generated independently
    # per ingress (so external refs round-trip correctly through the wire
    # protocol), but two semantically-equivalent ingress requests must
    # produce structurally-identical canonical messages otherwise.
    def normalize_messages(messages)
      messages.map do |m|
        h = m.is_a?(Hash) ? m.dup : m.to_h
        h.except(:id, :timestamp, :parent_id, :seq)
      end
    end

    it 'parses semantically equivalent payloads to identical canonical messages, system, tools, params' do
      anthropic_echo = echo_for('/v1/messages', anthropic_payload)
      responses_echo = echo_for('/v1/responses', responses_payload)

      # Identity fields on the request itself differ by design.
      identity_fields = %i[id conversation_id metadata caller routing messages]

      anthropic_core = anthropic_echo.except(*identity_fields)
      responses_core = responses_echo.except(*identity_fields)

      # Shape of canonical fields must be identical (tools, params, stream, system).
      expect(responses_core).to eq(anthropic_core)

      # Messages compared with per-message identity stripped.
      expect(normalize_messages(responses_echo[:messages])).to eq(
        normalize_messages(anthropic_echo[:messages])
      )

      # Sanity: the param normalization actually happened.
      # Anthropic: max_tokens; Responses: max_output_tokens — both fold to params.max_tokens.
      expect(anthropic_echo[:params][:max_tokens]).to eq(1024)
      expect(responses_echo[:params][:max_tokens]).to eq(1024)
      expect(anthropic_echo[:params][:temperature]).to eq(0.7)
      expect(responses_echo[:params][:temperature]).to eq(0.7)
    end
  end
end
