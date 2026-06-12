# frozen_string_literal: true

# Tool-call argument typing oracle. The two client wire formats have
# INCOMPATIBLE shape requirements for tool arguments:
#
#   Anthropic /v1/messages:
#     tool_use.input         MUST be an Object/Hash
#     server_tool_use.input  MUST be an Object/Hash
#
#   OpenAI /v1/responses + /v1/chat/completions:
#     function_call.arguments  MUST be a JSON String
#     (response output items + chat tool_calls + server function_call shape)
#
# A single uniform helper ("everything is a JSON string") was the bug behind
# the claude/vllm multi-turn regression where tool_use.input surfaced as a
# JSON string (or worse — a coerced numeric like 1.01 from a degraded model
# output). The fix lives in client_translators/shared_extractors.rb
# (`args_as_object` for Anthropic, `args_as_json_string` for OpenAI). This
# spec is the missing oracle: it asserts BOTH shapes simultaneously across
# normal Hash args, degraded numeric/string args, and the G24 server-tool
# block path. Without these assertions, 3056 specs were green while the
# bug shipped.

require_relative 'matrix_helper'

RSpec.describe '[matrix] tool-call argument typing per format', type: :request do
  include Rack::Test::Methods

  let(:app) { MatrixHelper.app_class }

  before do
    MatrixHelper.configure_for_fake!
  end

  after do
    MatrixHelper.restore_started_state!
  end

  let(:bash_tool) { { name: 'bash', description: 'shell', input_schema: { type: 'object' } } }

  describe '/v1/messages — Anthropic format requires tool_use.input as Hash' do
    it 'normal Hash args reach the wire as an Object' do
      FakeProvider.with_scenario(:tool_single) do
        post '/v1/messages',
             Legion::JSON.dump({
                                 model:      'fake-default',
                                 max_tokens: 1024,
                                 messages:   [{ role: 'user', content: 'list files' }],
                                 tools:      [bash_tool]
                               }),
             'CONTENT_TYPE' => 'application/json'
      end

      expect(last_response.status).to eq(200), -> { "got #{last_response.status}: #{last_response.body[0, 300]}" }
      body = Legion::JSON.load(last_response.body)
      tool_use = body[:content].find { |b| b[:type] == 'tool_use' }
      expect(tool_use).not_to be_nil
      expect(tool_use[:input]).to be_a(Hash),
                                  "Anthropic tool_use.input must be a Hash; got #{tool_use[:input].class}: #{tool_use[:input].inspect}"
      expect(tool_use[:input]).to eq(command: 'ls -la')
    end

    it 'degraded numeric args coerce to {} rather than violating the contract' do
      FakeProvider.with_scenario(:tool_degraded_args) do
        post '/v1/messages',
             Legion::JSON.dump({
                                 model:      'fake-default',
                                 max_tokens: 1024,
                                 messages:   [{ role: 'user', content: 'run a command' }],
                                 tools:      [bash_tool]
                               }),
             'CONTENT_TYPE' => 'application/json'
      end

      expect(last_response.status).to eq(200), -> { "got #{last_response.status}: #{last_response.body[0, 300]}" }
      body = Legion::JSON.load(last_response.body)
      tool_use = body[:content].find { |b| b[:type] == 'tool_use' }
      expect(tool_use).not_to be_nil
      expect(tool_use[:input]).to be_a(Hash),
                                  'Anthropic tool_use.input must be a Hash even when the upstream provider ' \
                                  "emitted a degraded shape (got #{tool_use[:input].class}: #{tool_use[:input].inspect}). " \
                                  "This is the claude/vllm multi-turn 'tool_use block #1 has input hash' regression."
      expect(tool_use[:input]).to eq({})
    end

    it 'G24 server_tool_use.input is also a Hash' do
      MatrixHelper.register_legion_tool!
      FakeProvider.with_scenario(:server_tool_legion) do
        post '/v1/messages',
             Legion::JSON.dump({
                                 model:      'fake-default',
                                 max_tokens: 1024,
                                 messages:   [{ role: 'user', content: 'list legionio tools' }]
                               }),
             'CONTENT_TYPE' => 'application/json'
      end

      expect(last_response.status).to eq(200), -> { "got #{last_response.status}: #{last_response.body[0, 300]}" }
      body = Legion::JSON.load(last_response.body)
      server_use = body[:content].find { |b| b[:type] == 'server_tool_use' }
      expect(server_use).not_to be_nil
      expect(server_use[:input]).to be_a(Hash)
    ensure
      MatrixHelper.unregister_legion_tool!
    end
  end

  let(:openai_bash_tool) { { type: 'function', name: 'bash', parameters: { type: 'object' } } }

  describe '/v1/responses — OpenAI format requires function_call.arguments as JSON String' do
    it 'normal Hash args serialise to a JSON string on the wire' do
      FakeProvider.with_scenario(:tool_single) do
        post '/v1/responses',
             Legion::JSON.dump({ model: 'fake-default', input: 'list files', tools: [openai_bash_tool] }),
             'CONTENT_TYPE' => 'application/json'
      end

      expect(last_response.status).to eq(200), -> { "got #{last_response.status}: #{last_response.body[0, 300]}" }
      body = Legion::JSON.load(last_response.body)
      function_call = body[:output].find { |i| i[:type] == 'function_call' }
      expect(function_call).not_to be_nil
      expect(function_call[:arguments]).to be_a(String),
                                           "OpenAI Responses function_call.arguments must be a JSON String; got #{function_call[:arguments].class}: #{function_call[:arguments].inspect}"
      expect(Legion::JSON.load(function_call[:arguments])).to eq(command: 'ls -la')
    end

    it 'degraded numeric args still serialise to a JSON string' do
      FakeProvider.with_scenario(:tool_degraded_args) do
        post '/v1/responses',
             Legion::JSON.dump({ model: 'fake-default', input: 'run a command', tools: [openai_bash_tool] }),
             'CONTENT_TYPE' => 'application/json'
      end

      expect(last_response.status).to eq(200), -> { "got #{last_response.status}: #{last_response.body[0, 300]}" }
      body = Legion::JSON.load(last_response.body)
      function_call = body[:output].find { |i| i[:type] == 'function_call' }
      expect(function_call).not_to be_nil
      expect(function_call[:arguments]).to be_a(String),
                                           "OpenAI Responses function_call.arguments must be a JSON String even on degraded provider output; got #{function_call[:arguments].class}"
    end

    it 'G24 server function_call.arguments is also a JSON String' do
      MatrixHelper.register_legion_tool!
      FakeProvider.with_scenario(:server_tool_legion) do
        post '/v1/responses',
             Legion::JSON.dump({ model: 'fake-default', input: 'list legionio tools' }),
             'CONTENT_TYPE' => 'application/json'
      end

      expect(last_response.status).to eq(200)
      body = Legion::JSON.load(last_response.body)
      function_calls = body[:output].select { |i| i[:type] == 'function_call' }
      expect(function_calls).not_to be_empty
      function_calls.each do |fc|
        expect(fc[:arguments]).to be_a(String)
      end
    ensure
      MatrixHelper.unregister_legion_tool!
    end
  end

  let(:chat_bash_tool) { { type: 'function', function: { name: 'bash', parameters: { type: 'object' } } } }

  describe '/v1/chat/completions — OpenAI format requires function.arguments as JSON String' do
    it 'normal Hash args serialise to a JSON string on the wire' do
      FakeProvider.with_scenario(:tool_single) do
        post '/v1/chat/completions',
             Legion::JSON.dump({
                                 model:    'fake-default',
                                 messages: [{ role: 'user', content: 'list files' }],
                                 tools:    [chat_bash_tool]
                               }),
             'CONTENT_TYPE' => 'application/json'
      end

      expect(last_response.status).to eq(200), -> { "got #{last_response.status}: #{last_response.body[0, 300]}" }
      body = Legion::JSON.load(last_response.body)
      tool_calls = body[:choices].first[:message][:tool_calls] || []
      expect(tool_calls).not_to be_empty
      tool_calls.each do |tc|
        args = tc[:function][:arguments]
        expect(args).to be_a(String),
                        "OpenAI chat function.arguments must be a JSON String; got #{args.class}: #{args.inspect}"
      end
    end

    it 'degraded numeric args still serialise to a JSON string' do
      FakeProvider.with_scenario(:tool_degraded_args) do
        post '/v1/chat/completions',
             Legion::JSON.dump({
                                 model:    'fake-default',
                                 messages: [{ role: 'user', content: 'run a command' }],
                                 tools:    [chat_bash_tool]
                               }),
             'CONTENT_TYPE' => 'application/json'
      end

      expect(last_response.status).to eq(200), -> { "got #{last_response.status}: #{last_response.body[0, 300]}" }
      body = Legion::JSON.load(last_response.body)
      tool_calls = body[:choices].first[:message][:tool_calls] || []
      tool_calls.each do |tc|
        expect(tc[:function][:arguments]).to be_a(String)
      end
    end
  end
end
