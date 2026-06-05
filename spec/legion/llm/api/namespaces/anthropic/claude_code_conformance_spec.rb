# frozen_string_literal: true

require 'spec_helper'
require 'rack/test'
require 'sinatra/base'
require 'legion/llm/api/namespaces/registration'

RSpec.describe 'Claude Code Drop-in Conformance' do
  include Rack::Test::Methods

  let(:app) do
    klass = Class.new(Sinatra::Base)
    klass.set :host_authorization, permitted: :any
    Legion::LLM::API::Namespaces::Registration.registered(klass)
    klass
  end

  let(:claude_code_headers) do
    {
      'CONTENT_TYPE'           => 'application/json',
      'HTTP_X_API_KEY'         => 'legion',
      'HTTP_ANTHROPIC_VERSION' => '2023-06-01'
    }
  end

  before do
    allow(Legion::LLM).to receive(:started?).and_return(true)
  end

  describe 'POST /v1/messages (what Claude Code sends)' do
    let(:mock_response) do
      instance_double(Legion::LLM::Inference::Response,
                      message:  { content: 'I can help with that.' },
                      routing:  { model: 'legionio', provider: :anthropic },
                      tokens:   { input: 15, output: 6 },
                      tools:    nil,
                      stop:     { reason: 'end_turn' },
                      thinking: nil)
    end

    before do
      allow(mock_response).to receive(:respond_to?).and_return(true)
      mock_executor = instance_double(Legion::LLM::Inference::Executor)
      allow(Legion::LLM::Inference::Executor).to receive(:new).and_return(mock_executor)
      allow(mock_executor).to receive(:call).and_return(mock_response)
    end

    it 'accepts x-api-key auth' do
      post '/v1/messages',
           Legion::JSON.dump({ model: 'legionio', messages: [{ role: 'user', content: 'hi' }], max_tokens: 4096 }),
           claude_code_headers
      expect(last_response.status).to eq(200)
    end

    it 'requires max_tokens (Claude Code always sends this)' do
      post '/v1/messages',
           Legion::JSON.dump({ model: 'legionio', messages: [{ role: 'user', content: 'hi' }] }),
           claude_code_headers
      expect(last_response.status).to eq(400)
      body = Legion::JSON.load(last_response.body)
      expect(body[:error][:type]).to eq('invalid_request_error')
    end

    it 'accepts system as top-level param (not a message)' do
      post '/v1/messages',
           Legion::JSON.dump({
                               model:      'legionio',
                               system:     'You are a coding assistant.',
                               messages:   [{ role: 'user', content: 'explain this code' }],
                               max_tokens: 4096
                             }),
           claude_code_headers
      expect(last_response.status).to eq(200)
    end

    it 'accepts tools with input_schema (not parameters)' do
      post '/v1/messages',
           Legion::JSON.dump({
                               model:      'legionio',
                               messages:   [{ role: 'user', content: 'read file.rb' }],
                               max_tokens: 4096,
                               tools:      [{ name: 'Read', description: 'Read a file',
input_schema: { type: 'object', properties: { file_path: { type: 'string' } }, required: ['file_path'] } }]
                             }),
           claude_code_headers
      expect(last_response.status).to eq(200)
    end

    it 'returns message with content array' do
      post '/v1/messages',
           Legion::JSON.dump({ model: 'legionio', messages: [{ role: 'user', content: 'hi' }], max_tokens: 4096 }),
           claude_code_headers
      body = Legion::JSON.load(last_response.body)
      expect(body[:type]).to eq('message')
      expect(body[:role]).to eq('assistant')
      expect(body[:content]).to be_an(Array)
      expect(body[:content].first[:type]).to eq('text')
      expect(body[:stop_reason]).to eq('end_turn')
      expect(body[:usage][:input_tokens]).to eq(15)
      expect(body[:usage][:output_tokens]).to eq(6)
    end

    it 'returns model field matching request' do
      post '/v1/messages',
           Legion::JSON.dump({ model: 'legionio', messages: [{ role: 'user', content: 'hi' }], max_tokens: 4096 }),
           claude_code_headers
      body = Legion::JSON.load(last_response.body)
      expect(body[:model]).to eq('legionio')
    end
  end

  describe 'POST /v1/messages streaming (what Claude Code uses)' do
    before do
      mock_executor = instance_double(Legion::LLM::Inference::Executor)
      mock_response = instance_double(Legion::LLM::Inference::Response,
                                      message: { content: 'Done.' },
                                      routing: { model: 'legionio' },
                                      tokens:  { input: 10, output: 4 },
                                      tools:   nil,
                                      stop:    { reason: 'end_turn' })
      allow(mock_response).to receive(:respond_to?).and_return(true)
      allow(Legion::LLM::Inference::Executor).to receive(:new).and_return(mock_executor)
      allow(mock_executor).to receive(:call_stream).and_yield(
        double(content: 'Done.', thinking: nil, respond_to?: true)
      ).and_return(mock_response)
    end

    it 'emits events in correct Anthropic protocol order' do
      post '/v1/messages',
           Legion::JSON.dump({ model: 'legionio', messages: [{ role: 'user', content: 'hi' }], max_tokens: 4096, stream: true }),
           claude_code_headers.merge('HTTP_ACCEPT' => 'text/event-stream')

      events = last_response.body.scan(/^event: (.+)$/).flatten
      # Strict ordering: message_start first, message_stop last
      expect(events.first).to eq('message_start')
      expect(events.last).to eq('message_stop')
      # Opening events (pre-emitted before stream loop) come before any delta
      delta_idx = events.index('content_block_delta')
      expect(events.index('content_block_start')).to be < delta_idx
      expect(events.index('ping')).to be < delta_idx
      # All required events present
      expect(events).to include('content_block_delta')
      expect(events).to include('content_block_stop')
      expect(events).to include('message_delta')
    end

    it 'message_start contains message object with usage' do
      post '/v1/messages',
           Legion::JSON.dump({ model: 'legionio', messages: [{ role: 'user', content: 'hi' }], max_tokens: 4096, stream: true }),
           claude_code_headers.merge('HTTP_ACCEPT' => 'text/event-stream')

      message_start_line = last_response.body.lines.find { |l| l.start_with?('event: message_start') }
      data_line = last_response.body.lines[last_response.body.lines.index(message_start_line) + 1]
      data = Legion::JSON.load(data_line.sub('data: ', ''))
      expect(data[:type]).to eq('message_start')
      expect(data[:message][:role]).to eq('assistant')
      expect(data[:message][:usage]).to have_key(:input_tokens)
    end

    it 'content_block_delta contains text_delta type' do
      post '/v1/messages',
           Legion::JSON.dump({ model: 'legionio', messages: [{ role: 'user', content: 'hi' }], max_tokens: 4096, stream: true }),
           claude_code_headers.merge('HTTP_ACCEPT' => 'text/event-stream')

      delta_lines = last_response.body.lines.select { |l| l.include?('"content_block_delta"') }
      expect(delta_lines).not_to be_empty
      delta_data = Legion::JSON.load(delta_lines.first.sub('data: ', ''))
      expect(delta_data[:delta][:type]).to eq('text_delta')
    end
  end
end
