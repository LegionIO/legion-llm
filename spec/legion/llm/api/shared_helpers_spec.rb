# frozen_string_literal: true

require 'spec_helper'
require 'rack/test'
require 'sinatra/base'

require 'legion/llm/api/shared_helpers'

RSpec.describe Legion::LLM::API::SharedHelpers do
  include Rack::Test::Methods

  def app
    @app ||= Class.new(Sinatra::Base) do
      set :host_authorization, permitted: :any
      helpers Legion::LLM::API::SharedHelpers

      post '/test/parse' do
        body = parse_request_body
        content_type :json
        Legion::JSON.dump({ parsed: body })
      end

      get '/test/require_llm' do
        require_llm!
        'ok'
      end

      post '/test/validate' do
        body = parse_request_body
        validate_required!(body, :model, :messages)
        'valid'
      end

      get '/test/json_response' do
        json_response({ hello: 'world' })
      end

      get '/test/json_error' do
        json_error('not_found', 'thing not found', status_code: 404)
      end

      post '/test/tools' do
        body = parse_request_body
        tools = build_tool_definitions(body[:tools])
        content_type :json
        Legion::JSON.dump({ count: tools.size, names: tools.map(&:name) })
      end

      post '/test/caller' do
        caller = build_server_caller(source: 'test', path: request.path, env: env)
        content_type :json
        Legion::JSON.dump({ source: caller[:source], has_requested_by: !!caller[:requested_by] })
      end

      post '/test/validate_messages' do
        body = parse_request_body
        validate_messages!(body[:messages])
        'ok'
      end

      post '/test/validate_tools' do
        body = parse_request_body
        validate_tools!(body[:tools])
        'ok'
      end
    end
  end
  describe '#parse_request_body' do
    it 'parses JSON with symbol keys (no double-transform needed)' do
      post '/test/parse', Legion::JSON.dump({ model: 'gpt-4' }), 'CONTENT_TYPE' => 'application/json'
      expect(last_response.status).to eq(200)
      result = Legion::JSON.load(last_response.body)
      expect(result[:parsed][:model]).to eq('gpt-4')
    end

    it 'returns 400 for invalid JSON' do
      post '/test/parse', 'not{json', 'CONTENT_TYPE' => 'application/json'
      expect(last_response.status).to eq(400)
      result = Legion::JSON.load(last_response.body)
      expect(result[:error][:code]).to eq('invalid_json')
    end

    it 'returns empty hash for empty body' do
      post '/test/parse', '', 'CONTENT_TYPE' => 'application/json'
      expect(last_response.status).to eq(200)
      result = Legion::JSON.load(last_response.body)
      expect(result[:parsed]).to eq({})
    end

    it 'returns 400 for non-object JSON' do
      post '/test/parse', '[1,2,3]', 'CONTENT_TYPE' => 'application/json'
      expect(last_response.status).to eq(400)
      result = Legion::JSON.load(last_response.body)
      expect(result[:error][:code]).to eq('invalid_request_body')
    end
  end

  describe '#require_llm!' do
    it 'halts 503 when LLM not started' do
      allow(Legion::LLM).to receive(:started?).and_return(false)
      get '/test/require_llm'
      expect(last_response.status).to eq(503)
    end

    it 'passes when LLM started' do
      allow(Legion::LLM).to receive(:started?).and_return(true)
      get '/test/require_llm'
      expect(last_response.status).to eq(200)
    end
  end

  describe '#validate_required!' do
    it 'halts 400 when required fields missing' do
      post '/test/validate', Legion::JSON.dump({ model: 'gpt-4' }), 'CONTENT_TYPE' => 'application/json'
      expect(last_response.status).to eq(400)
      result = Legion::JSON.load(last_response.body)
      expect(result[:error][:code]).to eq('missing_fields')
      expect(result[:error][:message]).to include('messages')
    end

    it 'passes when all required fields present' do
      post '/test/validate', Legion::JSON.dump({ model: 'gpt-4', messages: [{ role: 'user', content: 'hi' }] }), 'CONTENT_TYPE' => 'application/json'
      expect(last_response.status).to eq(200)
    end
  end

  describe '#json_response' do
    it 'wraps data and returns 200' do
      get '/test/json_response'
      expect(last_response.status).to eq(200)
      expect(last_response.content_type).to include('application/json')
      result = Legion::JSON.load(last_response.body)
      expect(result[:data][:hello]).to eq('world')
    end
  end

  describe '#json_error' do
    it 'returns native error format with status' do
      get '/test/json_error'
      expect(last_response.status).to eq(404)
      result = Legion::JSON.load(last_response.body)
      expect(result[:error][:code]).to eq('not_found')
      expect(result[:error][:message]).to eq('thing not found')
    end
  end

  describe '#build_tool_definitions' do
    it 'builds ToolDefinition objects from specs' do
      tools = [
        { name: 'get_weather', description: 'Get weather', parameters: { type: 'object' } },
        { name: 'search', description: 'Search web', input_schema: { type: 'object' } }
      ]
      post '/test/tools', Legion::JSON.dump({ tools: tools }), 'CONTENT_TYPE' => 'application/json'
      expect(last_response.status).to eq(200)
      result = Legion::JSON.load(last_response.body)
      expect(result[:count]).to eq(2)
      expect(result[:names]).to eq(%w[get_weather search])
    end

    it 'skips tools with empty names' do
      tools = [{ name: '', description: 'bad' }, { name: 'good', description: 'ok', parameters: {} }]
      post '/test/tools', Legion::JSON.dump({ tools: tools }), 'CONTENT_TYPE' => 'application/json'
      result = Legion::JSON.load(last_response.body)
      expect(result[:count]).to eq(1)
    end

    it 'returns empty array for nil' do
      post '/test/tools', Legion::JSON.dump({ tools: nil }), 'CONTENT_TYPE' => 'application/json'
      result = Legion::JSON.load(last_response.body)
      expect(result[:count]).to eq(0)
    end
  end

  describe '#build_server_caller' do
    it 'includes source, path, and requested_by identity' do
      post '/test/caller', '', 'CONTENT_TYPE' => 'application/json'
      expect(last_response.status).to eq(200)
      result = Legion::JSON.load(last_response.body)
      expect(result[:source]).to eq('test')
      expect(result[:has_requested_by]).to be true
    end
  end

  describe '#validate_messages!' do
    it 'halts 400 when a message has no role' do
      post '/test/validate_messages',
           Legion::JSON.dump({ messages: [{ content: 'hi' }] }),
           'CONTENT_TYPE' => 'application/json'
      expect(last_response.status).to eq(400)
      result = Legion::JSON.load(last_response.body)
      expect(result[:error][:code]).to eq('invalid_messages')
    end

    it 'passes when all messages are valid' do
      post '/test/validate_messages',
           Legion::JSON.dump({ messages: [{ role: 'user', content: 'hi' }] }),
           'CONTENT_TYPE' => 'application/json'
      expect(last_response.status).to eq(200)
    end
  end

  describe '#validate_tools!' do
    it 'halts 400 when tools is not an array' do
      post '/test/validate_tools',
           Legion::JSON.dump({ tools: 'bad' }),
           'CONTENT_TYPE' => 'application/json'
      expect(last_response.status).to eq(400)
    end

    it 'passes for valid tool array' do
      post '/test/validate_tools',
           Legion::JSON.dump({ tools: [{ name: 'search', description: 'Search', parameters: {} }] }),
           'CONTENT_TYPE' => 'application/json'
      expect(last_response.status).to eq(200)
    end
  end
end
