# frozen_string_literal: true

require 'spec_helper'
require 'rack/test'
require 'sinatra/base'
require 'sinatra/namespace'
require 'legion/llm/api/namespaces/helpers'

RSpec.describe 'Namespaces::OpenAI::Responses' do
  include Rack::Test::Methods

  before do
    require 'legion/llm/api/namespaces/openai/responses'
  end

  let(:app) do
    Class.new(Sinatra::Base) do
      set :host_authorization, permitted: :any
      register Sinatra::Namespace
      helpers Legion::Logging::Helper
      helpers Legion::LLM::API::Namespaces::Helpers
      register Legion::LLM::API::Namespaces::OpenAI::Responses
    end
  end

  let(:executor_double) do
    double('Executor').tap do |ex|
      allow(ex).to receive(:stream_preflight!).and_return(nil)
      allow(ex).to receive(:call_stream).and_return(
        double('Response', routing: { model: 'legionio' }, tokens: { input_tokens: 5, output_tokens: 10 }, tools: [])
      )
      # N×N: call_responses delegates to canonical paths (call / call_stream).
      # The API namespace translator converts Responses API format to canonical
      # before the executor receives it.
      # M7/G3: the envelope carries the stop reason (a real completion has
      # one) and a canonical/absent thinking — the double matches the real
      # boundary (R15).
      allow(ex).to receive(:call).and_return(
        double('Response', routing: { model: 'legionio' }, tokens: { input_tokens: 5, output_tokens: 10 },
                           message: { content: 'Hello' }, tools: [],
                           stop: { reason: 'end_turn' }, thinking: nil)
      )
    end
  end

  before do
    allow(Legion::LLM).to receive(:started?).and_return(true)
    allow(Legion::LLM::Inference::Request).to receive(:build).and_return(double('Request'))
    allow(Legion::LLM::Inference::Executor).to receive(:new).and_return(executor_double)
    Legion::Settings[:llm][:default_model] = 'legionio'
  end

  describe 'POST /v1/responses' do
    it 'returns 400 when input is missing' do
      post '/v1/responses', Legion::JSON.dump({ model: 'legionio' }), 'CONTENT_TYPE' => 'application/json'
      expect(last_response.status).to eq(400)
      body = Legion::JSON.load(last_response.body)
      expect(body[:error][:type]).to eq('invalid_request_error')
    end

    context 'non-streaming' do
      it 'returns sync response object via canonical call path' do
        post '/v1/responses',
             Legion::JSON.dump({ input: 'Hello', model: 'legionio', stream: false }),
             'CONTENT_TYPE' => 'application/json'
        expect(last_response.status).to eq(200)
        body = Legion::JSON.load(last_response.body)
        expect(body[:object]).to eq('response')
        expect(body[:status]).to eq('completed')
        expect(body[:output]).to be_an(Array)
      end

      it 'returns completed status with a function_call item when client tool calls are present' do
        # G3: a canonical client tool call carries the closed source enum and
        # a result member — the double matches the real boundary (R15).
        tool_call = double('ToolCall', name: 'get_weather', id: 'tc_1', arguments: { location: 'NYC' },
                                     source: :client, result: nil)
        allow(executor_double).to receive(:call).and_return(
          double('Response',
                 routing:  { model: 'legionio' },
                 tokens:   { input_tokens: 5, output_tokens: 10 },
                 message:  { content: 'Let me check.' },
                 tools:    [tool_call],
                 stop:     { reason: 'end_turn' },
                 thinking: nil)
        )
        post '/v1/responses',
             Legion::JSON.dump({ input: 'Weather?', model: 'legionio', stream: false }),
             'CONTENT_TYPE' => 'application/json'
        expect(last_response.status).to eq(200)
        body = Legion::JSON.load(last_response.body)
        # Responses protocol: client-callable calls ride in a completed response as
        # function_call items; the client executes them and continues via
        # function_call_output. No requires_action/action_required (Assistants API).
        expect(body[:status]).to eq('completed')
        expect(body[:output].any? { |i| i[:type] == 'function_call' && i[:name] == 'get_weather' }).to be(true)
        expect(body[:action_required]).to be_nil
      end

      # N×N: all providers are treated the same — no provider-specific branches.
      context 'with any provider (openai, vllm, ollama, etc.)' do
        it 'uses the canonical call path regardless of provider type' do
          post '/v1/responses',
               Legion::JSON.dump({ input: 'Hello', model: 'legionio', stream: false }),
               'CONTENT_TYPE' => 'application/json'
          expect(last_response.status).to eq(200)
          expect(executor_double).to have_received(:call)
        end
      end
    end

    context 'streaming' do
      it 'streams typed SSE events via canonical call_stream path' do
        pipeline_response = double('Response',
                                   routing: { model: 'legionio' },
                                   tokens:  { input_tokens: 5, output_tokens: 10 },
                                   tools:   [])
        allow(executor_double).to receive(:stream_preflight!).and_return(nil)
        allow(executor_double).to receive(:call_stream) do |&block|
          # G3/L2: Canonical::Chunk only (the legacy double('Chunk') shape is
          # gone; R15).
          block.call(Legion::Extensions::Llm::Canonical::Chunk.text_delta(delta: 'Hello ', request_id: 'req_orsp'))
          block.call(Legion::Extensions::Llm::Canonical::Chunk.text_delta(delta: 'world', request_id: 'req_orsp'))
          pipeline_response
        end
        post '/v1/responses',
             Legion::JSON.dump({ input: 'Hi', model: 'legionio', stream: true }),
             'CONTENT_TYPE' => 'application/json'
        expect(last_response.content_type).to include('text/event-stream')
        expect(last_response.body).to include('event: response.created')
        expect(last_response.body).to include('event: response.output_text.delta')
        expect(last_response.body).to include('event: response.completed')
        expect(last_response.body).not_to include('data: [DONE]')
        expect(executor_double).to have_received(:call_stream)
      end

      # N×N: all providers are treated the same — no provider-specific streaming.
      context 'with any provider (openai, vllm, ollama, etc.)' do
        it 'uses call_stream regardless of provider type' do
          pipeline_response = double('Response',
                                     routing: { model: 'legionio' },
                                     tokens:  { input_tokens: 5, output_tokens: 10 },
                                     tools:   [])
          allow(executor_double).to receive(:stream_preflight!).and_return(nil)
          allow(executor_double).to receive(:call_stream).and_return(pipeline_response)
          post '/v1/responses',
               Legion::JSON.dump({ input: 'Hi', model: 'legionio', stream: true }),
               'CONTENT_TYPE' => 'application/json'
          expect(last_response.content_type).to include('text/event-stream')
          expect(executor_double).to have_received(:call_stream)
        end
      end
    end
  end

  describe '.normalize_input_array' do
    subject { Legion::LLM::API::Namespaces::OpenAI::Responses }

    it 'maps developer role to system' do
      result = subject.normalize_input_array([{ role: 'developer', content: 'You are an expert.' }])
      expect(result).to eq([{ role: 'system', content: 'You are an expert.' }])
    end

    it 'preserves standard roles unchanged' do
      result = subject.normalize_input_array([
                                               { role: 'user', content: 'hello' },
                                               { role: 'assistant', content: 'hi' }
                                             ])
      expect(result.map { |m| m[:role] }).to eq(%w[user assistant])
    end

    it 'mixes developer and user roles correctly' do
      result = subject.normalize_input_array([
                                               { role: 'developer', content: 'Be concise.' },
                                               { role: 'user', content: 'explain ruby' }
                                             ])
      expect(result.first[:role]).to eq('system')
      expect(result.last[:role]).to eq('user')
    end

    # Dead-stop root cause: an assistant `message` arriving AFTER function_call(s)
    # and BEFORE their outputs (the Codex/Responses order) was split into a
    # SEPARATE assistant message, producing assistant(tool_calls) → assistant(text)
    # → tool. That wedges narration between a tool_call and its result and makes
    # thinking-enabled models narrate-and-stop. It must stay ONE assistant turn.
    it 'merges assistant text-after-calls into one assistant turn (no split)' do
      result = subject.normalize_input_array([
                                               { type: 'function_call', call_id: 'call_A', name: 'exec_command', arguments: '{}' },
                                               { role: 'assistant', content: 'checking now' },
                                               { type: 'function_call_output', call_id: 'call_A', output: 'ok' }
                                             ])
      roles = result.map { |m| m[:role] }
      expect(roles.each_cons(2).count { |a, b| a == 'assistant' && b == 'assistant' }).to eq(0)
      expect(roles).to eq(%w[assistant tool])
      assistant = result.find { |m| m[:role] == 'assistant' }
      expect(assistant[:tool_calls]).to be_an(Array)
      expect(assistant[:content].to_s).to include('checking now')
    end
  end

  describe 'GET /v1/responses/:id' do
    it 'returns 404 for unknown id' do
      get '/v1/responses/resp_unknown'
      expect(last_response.status).to eq(404)
    end
  end

  describe 'DELETE /v1/responses/:id' do
    it 'returns deleted stub' do
      delete '/v1/responses/resp_abc'
      expect(last_response.status).to eq(200)
      body = Legion::JSON.load(last_response.body)
      expect(body[:deleted]).to be(true)
      expect(body[:id]).to eq('resp_abc')
    end
  end

  describe 'GET /v1/responses/:id/input_items' do
    it 'returns empty list stub' do
      get '/v1/responses/resp_abc/input_items'
      expect(last_response.status).to eq(200)
      body = Legion::JSON.load(last_response.body)
      expect(body[:object]).to eq('list')
      expect(body[:data]).to eq([])
    end
  end

  describe 'POST /v1/responses/:id/input_tokens/count' do
    it 'returns token count estimate' do
      post '/v1/responses/resp_abc/input_tokens/count',
           Legion::JSON.dump({ input: 'How many tokens?', model: 'legionio' }),
           'CONTENT_TYPE' => 'application/json'
      expect(last_response.status).to eq(200)
      body = Legion::JSON.load(last_response.body)
      expect(body[:input_tokens]).to be_a(Integer)
      expect(body[:input_tokens]).to be > 0
    end
  end

  describe 'POST /api/llm/inference/v1/responses (legacy alias)' do
    it 'returns a response via the legacy path (same as /v1/responses)' do
      post '/api/llm/inference/v1/responses',
           Legion::JSON.dump({ input: 'Hello', model: 'legionio', stream: false }),
           'CONTENT_TYPE' => 'application/json'
      expect(last_response.status).to eq(200)
      body = Legion::JSON.load(last_response.body)
      expect(body[:object]).to eq('response')
    end
  end
end
