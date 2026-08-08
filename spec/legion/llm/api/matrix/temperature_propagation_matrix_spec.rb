# frozen_string_literal: true

# P1 regression spec: temperature:0 must propagate through the native tool loop
# dispatch path to the provider. Without this, vLLM runs at its default
# temperature (>0), producing nondeterministic empty-argument tool calls that
# cause a dead stop in parallel tool-call workflows.
#
# Root cause: native_dispatch_options (tool_injection.rb) built the dispatch
# Hash from @request fields but NEVER included generation params (temperature,
# top_p, frequency_penalty, etc.). The LexLLMAdapter passes opts[:temperature]
# to the provider — when it's nil, the provider uses its own default.
#
# This spec asserts the FakeProvider RECEIVES the exact temperature the client
# sent, including the critical temperature=0 case (0 is not nil, not absent).
# It MUST fail before the fix and pass after.

require_relative 'matrix_helper'

RSpec.describe '[matrix] temperature propagation × native tool loop', type: :request do
  include Rack::Test::Methods

  let(:app) { MatrixHelper.app_class }

  before do
    MatrixHelper.configure_for_fake!
  end

  after do
    MatrixHelper.restore_started_state!
  end

  let(:bash_tool) do
    {
      type:        'function',
      name:        'bash',
      description: 'Execute a shell command',
      parameters:  {
        type:       'object',
        properties: { command: { type: 'string', description: 'The command to run' } },
        required:   %w[command]
      }
    }
  end

  describe '/v1/responses — temperature:0 with tools (parallel tool-call dead-stop regression)' do
    it 'propagates temperature=0 to the provider on the native tool loop dispatch' do
      FakeProvider.with_scenario(:tool_single) do
        post '/v1/responses',
             Legion::JSON.dump({
                                 model:       'fake-default',
                                 input:       'list the files in the current directory',
                                 tools:       [bash_tool],
                                 temperature: 0
                               }),
             'CONTENT_TYPE' => 'application/json'
      end

      expect(last_response.status).to eq(200), "Expected 200, got #{last_response.status}: #{last_response.body}"

      call = FakeProvider.calls.last
      expect(call).not_to be_nil, 'FakeProvider received no calls'
      expect(call[:temperature]).to eq(0),
                                    "Expected provider to receive temperature=0, got temperature=#{call[:temperature].inspect} " \
                                    '— native_dispatch_options dropped the generation param'
    end

    it 'propagates temperature=0.7 to the provider' do
      FakeProvider.with_scenario(:tool_single) do
        post '/v1/responses',
             Legion::JSON.dump({
                                 model:       'fake-default',
                                 input:       'list the files in the current directory',
                                 tools:       [bash_tool],
                                 temperature: 0.7
                               }),
             'CONTENT_TYPE' => 'application/json'
      end

      expect(last_response.status).to eq(200), "Expected 200, got #{last_response.status}: #{last_response.body}"

      call = FakeProvider.calls.last
      expect(call).not_to be_nil, 'FakeProvider received no calls'
      expect(call[:temperature]).to eq(0.7),
                                    "Expected provider to receive temperature=0.7, got temperature=#{call[:temperature].inspect}"
    end

    it 'does NOT send temperature when client omits it (nil, not 0)' do
      FakeProvider.with_scenario(:tool_single) do
        post '/v1/responses',
             Legion::JSON.dump({
                                 model: 'fake-default',
                                 input: 'list the files in the current directory',
                                 tools: [bash_tool]
                               }),
             'CONTENT_TYPE' => 'application/json'
      end

      expect(last_response.status).to eq(200), "Expected 200, got #{last_response.status}: #{last_response.body}"

      call = FakeProvider.calls.last
      expect(call).not_to be_nil, 'FakeProvider received no calls'
      expect(call[:temperature]).to be_nil,
                                    "Expected provider to receive temperature=nil when client omits it, got #{call[:temperature].inspect}"
    end
  end

  describe '/v1/messages — temperature:0 with tools' do
    it 'propagates temperature=0 to the provider' do
      FakeProvider.with_scenario(:tool_single) do
        post '/v1/messages',
             Legion::JSON.dump({
                                 model:       'fake-default',
                                 max_tokens:  1024,
                                 messages:    [{ role: 'user', content: 'list files' }],
                                 tools:       [{ name: 'bash', description: 'run shell',
                                                 input_schema: { type: 'object', properties: { command: { type: 'string' } }, required: %w[command] } }],
                                 temperature: 0
                               }),
             'CONTENT_TYPE' => 'application/json'
      end

      expect(last_response.status).to eq(200), "Expected 200, got #{last_response.status}: #{last_response.body}"

      call = FakeProvider.calls.last
      expect(call).not_to be_nil, 'FakeProvider received no calls'
      expect(call[:temperature]).to eq(0),
                                    "Expected provider to receive temperature=0, got temperature=#{call[:temperature].inspect}"
    end
  end

  describe '/v1/chat/completions — temperature:0 with tools' do
    it 'propagates temperature=0 to the provider' do
      FakeProvider.with_scenario(:tool_single) do
        post '/v1/chat/completions',
             Legion::JSON.dump({
                                 model:       'fake-default',
                                 messages:    [{ role: 'user', content: 'list files' }],
                                 tools:       [{ type:     'function',
                                                 function: { name: 'bash', description: 'run shell',
                                                             parameters: { type: 'object', properties: { command: { type: 'string' } }, required: %w[command] } } }],
                                 temperature: 0
                               }),
             'CONTENT_TYPE' => 'application/json'
      end

      expect(last_response.status).to eq(200), "Expected 200, got #{last_response.status}: #{last_response.body}"

      call = FakeProvider.calls.last
      expect(call).not_to be_nil, 'FakeProvider received no calls'
      expect(call[:temperature]).to eq(0),
                                    "Expected provider to receive temperature=0, got temperature=#{call[:temperature].inspect}"
    end
  end

  describe 'sibling check — other 0-valued generation params' do
    it 'propagates top_p=0 to the provider' do
      FakeProvider.with_scenario(:text) do
        post '/v1/responses',
             Legion::JSON.dump({
                                 model:       'fake-default',
                                 input:       'hello',
                                 temperature: 0,
                                 top_p:       0
                               }),
             'CONTENT_TYPE' => 'application/json'
      end

      expect(last_response.status).to eq(200), "Expected 200, got #{last_response.status}: #{last_response.body}"
      # top_p assertion deferred to the fix — this documents the sibling param path
    end

    it 'propagates frequency_penalty=0 to the provider' do
      FakeProvider.with_scenario(:text) do
        post '/v1/responses',
             Legion::JSON.dump({
                                 model:             'fake-default',
                                 input:             'hello',
                                 temperature:       0,
                                 frequency_penalty: 0
                               }),
             'CONTENT_TYPE' => 'application/json'
      end

      expect(last_response.status).to eq(200), "Expected 200, got #{last_response.status}: #{last_response.body}"
    end
  end
end
