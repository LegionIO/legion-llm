# frozen_string_literal: true

require 'spec_helper'
require 'rack/test'
require 'sinatra/base'
require 'sinatra/namespace'
require 'legion/llm/api/namespaces/registration'

RSpec.describe 'Codex CLI conformance', :ssot_v3, type: :conformance do
  include Rack::Test::Methods

  # Build a minimal Sinatra app with namespace routes registered
  let(:app) do
    test_app = Class.new(Sinatra::Base) do
      set :host_authorization, permitted: :any
    end
    Legion::LLM::API::Namespaces::Registration.registered(test_app)
    test_app
  end

  before do
    allow(Legion::LLM).to receive(:started?).and_return(true)
    allow(Legion::LLM).to receive(:settings).and_return(
      Legion::LLM::Settings.default
    )
    # SSOT v3: GET /v1/models now projects the Phase 1 Registry snapshot via
    # ModelCatalog. Publish a policy-permitted supported inference offering so
    # the compat model view is non-empty and the auto-routing aliases
    # (legionio/auto/copilot-utility-small) are surfaced for Codex validation.
    activate(provider_family: 'vllm', instance_id: 'h200',
             drafts: [offering_draft(model: 'gemma4', supported: %i[chat], context: 200_000)])
  end

  # ─── GET /v1/models ────────────────────────────────────────────────────────

  describe 'GET /v1/models' do
    context 'with OpenAI-style Authorization header (Codex auth)' do
      before { get '/v1/models', {}, { 'HTTP_AUTHORIZATION' => 'Bearer any-value' } }

      it 'returns 200' do
        expect(last_response.status).to eq(200)
      end

      it 'returns application/json content-type' do
        expect(last_response.content_type).to include('application/json')
      end

      it 'returns an object key' do
        body = Legion::JSON.load(last_response.body)
        expect(body[:object]).to eq('list')
      end

      it 'returns a data array' do
        body = Legion::JSON.load(last_response.body)
        expect(body[:data]).to be_an(Array)
      end

      it 'includes at least one model entry' do
        body = Legion::JSON.load(last_response.body)
        expect(body[:data].size).to be >= 1
      end

      it 'each model entry has required fields: id, object, owned_by' do
        body = Legion::JSON.load(last_response.body)
        body[:data].each do |model|
          expect(model[:id]).to be_a(String)
          expect(model[:object]).to eq('model')
          expect(model[:owned_by]).to be_a(String)
        end
      end

      it 'includes a legionio model entry (required for Codex model validation)' do
        body = Legion::JSON.load(last_response.body)
        ids = body[:data].map { |m| m[:id] }
        expect(ids).to include('legionio')
      end
    end
  end

  # ─── POST /v1/responses (streaming) ────────────────────────────────────────

  describe 'POST /v1/responses (streaming)' do
    let(:codex_request) do
      {
        model:  'legionio',
        input:  [{ role: 'user', content: 'Say hello.' }],
        stream: true
      }
    end

    let(:fake_executor) { instance_double(Legion::LLM::Inference::Executor) }

    let(:fake_pipeline_response) do
      instance_double(
        Legion::LLM::Inference::Response,
        routing: { model: 'legionio' },
        tokens:  { input_tokens: 5, output_tokens: 2 },
        message: 'Hello world!',
        tools:   []
      )
    end

    let(:fake_chunks) do
      [
        Legion::LLM::Types::Chunk.content_delta(
          delta:      { text: 'Hello ' },
          request_id: 'req_test_123'
        ),
        Legion::LLM::Types::Chunk.content_delta(
          delta:      { text: 'world!' },
          request_id: 'req_test_123'
        ),
        Legion::LLM::Types::Chunk.done(
          request_id:  'req_test_123',
          usage:       { input_tokens: 5, output_tokens: 2 },
          stop_reason: 'end_turn'
        )
      ]
    end

    before do
      allow(Legion::LLM::Inference::Executor).to receive(:new).and_return(fake_executor)
      allow(fake_executor).to receive(:call_stream) do |&block|
        fake_chunks.each { |chunk| block.call(chunk) }
        fake_pipeline_response
      end
    end

    def parsed_sse_events(body)
      body.split("\n\n").filter_map do |block|
        lines = block.split("\n")
        event_line = lines.find { |l| l.start_with?('event: ') }
        data_line  = lines.find { |l| l.start_with?('data: ') }
        next unless event_line && data_line

        {
          event: event_line.sub('event: ', '').strip,
          data:  Legion::JSON.load(data_line.sub('data: ', '').strip)
        }
      end
    end

    before do
      post '/v1/responses',
           Legion::JSON.dump(codex_request),
           { 'CONTENT_TYPE' => 'application/json', 'HTTP_AUTHORIZATION' => 'Bearer any-value' }
    end

    it 'returns 200' do
      expect(last_response.status).to eq(200)
    end

    it 'returns text/event-stream content-type' do
      expect(last_response.content_type).to include('text/event-stream')
    end

    it 'emits response.created as the first event' do
      events = parsed_sse_events(last_response.body)
      expect(events.first[:event]).to eq('response.created')
    end

    it 'response.created payload has type=response.created' do
      events = parsed_sse_events(last_response.body)
      created = events.find { |e| e[:event] == 'response.created' }
      expect(created[:data][:type]).to eq('response.created')
    end

    it 'emits response.in_progress after response.created' do
      events = parsed_sse_events(last_response.body)
      event_names = events.map { |e| e[:event] }
      created_idx     = event_names.index('response.created')
      in_progress_idx = event_names.index('response.in_progress')
      expect(in_progress_idx).to be > created_idx
    end

    it 'emits response.output_item.added after response.in_progress' do
      events = parsed_sse_events(last_response.body)
      event_names = events.map { |e| e[:event] }
      in_progress_idx    = event_names.index('response.in_progress')
      output_item_idx    = event_names.index('response.output_item.added')
      expect(output_item_idx).to be > in_progress_idx
    end

    it 'emits response.content_part.added' do
      events = parsed_sse_events(last_response.body)
      expect(events.map { |e| e[:event] }).to include('response.content_part.added')
    end

    it 'emits at least one response.output_text.delta' do
      events = parsed_sse_events(last_response.body)
      deltas = events.select { |e| e[:event] == 'response.output_text.delta' }
      expect(deltas.size).to be >= 1
    end

    it 'response.output_text.delta payloads have a delta field' do
      events = parsed_sse_events(last_response.body)
      events.select { |e| e[:event] == 'response.output_text.delta' }.each do |e|
        expect(e[:data][:delta]).to be_a(String)
      end
    end

    it 'emits response.output_text.done' do
      events = parsed_sse_events(last_response.body)
      expect(events.map { |e| e[:event] }).to include('response.output_text.done')
    end

    it 'emits response.content_part.done' do
      events = parsed_sse_events(last_response.body)
      expect(events.map { |e| e[:event] }).to include('response.content_part.done')
    end

    it 'emits response.output_item.done' do
      events = parsed_sse_events(last_response.body)
      expect(events.map { |e| e[:event] }).to include('response.output_item.done')
    end

    it 'emits response.completed as the final event' do
      events = parsed_sse_events(last_response.body)
      expect(events.last[:event]).to eq('response.completed')
    end

    it 'response.completed payload has status=completed' do
      events = parsed_sse_events(last_response.body)
      completed = events.find { |e| e[:event] == 'response.completed' }
      expect(completed[:data][:response][:status]).to eq('completed')
    end

    it 'response.completed payload has usage with input_tokens and output_tokens' do
      events = parsed_sse_events(last_response.body)
      completed = events.find { |e| e[:event] == 'response.completed' }
      expect(completed[:data][:response][:usage][:input_tokens]).to be_a(Integer)
      expect(completed[:data][:response][:usage][:output_tokens]).to be_a(Integer)
    end

    it 'events appear in correct relative order' do
      events = parsed_sse_events(last_response.body)
      event_names = events.map { |e| e[:event] }
      required_order = %w[
        response.created
        response.in_progress
        response.output_item.added
        response.content_part.added
        response.output_text.delta
        response.output_text.done
        response.content_part.done
        response.output_item.done
        response.completed
      ]
      last_idx = -1
      required_order.each do |name|
        idx = event_names.index(name)
        expect(idx).not_to be_nil, "Expected event '#{name}' to be present in stream"
        expect(idx).to be > last_idx, "Expected '#{name}' (idx #{idx}) to appear after previous required event (idx #{last_idx})"
        last_idx = idx
      end
    end
  end

  # ─── POST /v1/responses (non-streaming) ────────────────────────────────────

  describe 'POST /v1/responses (non-streaming)' do
    let(:sync_request) do
      {
        model: 'legionio',
        input: [{ role: 'user', content: 'Say hello.' }]
        # stream: false (omitted = default false)
      }
    end

    let(:fake_executor) { instance_double(Legion::LLM::Inference::Executor) }
    let(:fake_pipeline_response) do
      instance_double(
        Legion::LLM::Inference::Response,
        routing: { model: 'legionio' },
        tokens:  { input_tokens: 5, output_tokens: 2 },
        message: 'Hello!',
        tools:   []
      )
    end

    # N×N: /v1/responses goes through the canonical call path, not a separate
    # provider-specific call_responses path. The translator converts Responses
    # API format to canonical before the executor receives it.
    before do
      allow(Legion::LLM::Inference::Executor).to receive(:new).and_return(fake_executor)
      allow(fake_executor).to receive(:call).and_return(fake_pipeline_response)

      post '/v1/responses',
           Legion::JSON.dump(sync_request),
           { 'CONTENT_TYPE' => 'application/json', 'HTTP_AUTHORIZATION' => 'Bearer any-value' }
    end

    it 'returns 200' do
      expect(last_response.status).to eq(200)
    end

    it 'returns application/json content-type' do
      expect(last_response.content_type).to include('application/json')
    end

    it 'returns object=response' do
      body = Legion::JSON.load(last_response.body)
      expect(body[:object]).to eq('response')
    end

    it 'returns status=completed' do
      body = Legion::JSON.load(last_response.body)
      expect(body[:status]).to eq('completed')
    end

    it 'returns output array with at least one item' do
      body = Legion::JSON.load(last_response.body)
      expect(body[:output]).to be_an(Array)
      expect(body[:output].size).to be >= 1
    end

    it 'output item has type=message, role=assistant' do
      body = Legion::JSON.load(last_response.body)
      item = body[:output].find { |i| i[:type] == 'message' }
      expect(item).not_to be_nil
      expect(item[:role]).to eq('assistant')
    end
  end
end
