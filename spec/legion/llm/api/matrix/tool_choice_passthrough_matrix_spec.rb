# frozen_string_literal: true

# Failing-test for the live regression where /v1/responses payloads pin
# tool_choice but the executor never forces the tool with the provider.
#
# Captured live evidence (legionio-e2e codex/vllm tool_call cell post-G25):
# the spec sends `tool_choice: {type: 'function', name: 'bash'}` with
# temperature 0; the daemon returns 0 function_calls instead of the
# expected 1. Tracing showed that NONE of the three client translators
# (anthropic_messages, openai_responses, openai_chat) read body[:tool_choice]
# or thread it into Canonical::Request.tool_choice. Inference::Request
# defaults to {mode: :auto}, so native_tool_prefs returns nil for the
# choice and the provider gets no tool_choice in the dispatch payload.
#
# This spec is the in-process oracle: send a tool_choice through each of
# the three client routes and assert the FakeProvider RECEIVED a
# tool_prefs with the forced choice. When the harness goes green, every
# real provider (vLLM, OpenAI, Bedrock, Anthropic, Ollama) will receive
# the same choice and respect it.

require_relative 'matrix_helper'

RSpec.describe '[matrix] tool_choice passthrough × FakeProvider', type: :request do
  include Rack::Test::Methods

  let(:app) { MatrixHelper.app_class }

  before do
    MatrixHelper.configure_for_fake!
  end

  after do
    MatrixHelper.restore_started_state!
  end

  describe '/v1/messages — anthropic tool_choice' do
    it 'threads body.tool_choice to FakeProvider as tool_prefs' do
      FakeProvider.with_scenario(:tool_single) do
        post '/v1/messages',
             Legion::JSON.dump({
                                 model:       'fake-default',
                                 max_tokens:  1024,
                                 messages:    [{ role: 'user', content: 'list files' }],
                                 tools:       [{ name: 'bash', description: 'run', input_schema: { type: 'object', properties: { command: { type: 'string' } }, required: %w[command] } }],
                                 tool_choice: { type: 'tool', name: 'bash' }
                               }),
             'CONTENT_TYPE' => 'application/json'
      end

      expect(last_response.status).to eq(200)

      call = FakeProvider.calls.last
      expect(call).not_to be_nil
      tool_prefs = call[:tool_prefs]
      expect(tool_prefs).not_to be_nil,
                                'FakeProvider received no tool_prefs — translator dropped tool_choice'
      expect(tool_prefs[:choice]).to eq(:bash).or eq('bash')
    end
  end

  describe '/v1/responses — codex tool_choice' do
    it 'threads body.tool_choice to FakeProvider as tool_prefs' do
      FakeProvider.with_scenario(:tool_single) do
        post '/v1/responses',
             Legion::JSON.dump({
                                 model:       'fake-default',
                                 input:       'list files',
                                 tools:       [{ type: 'function', name: 'bash', description: 'run',
parameters: { type: 'object', properties: { command: { type: 'string' } }, required: %w[command] } }],
                                 tool_choice: { type: 'function', name: 'bash' }
                               }),
             'CONTENT_TYPE' => 'application/json'
      end

      expect(last_response.status).to eq(200)

      call = FakeProvider.calls.last
      expect(call).not_to be_nil
      tool_prefs = call[:tool_prefs]
      expect(tool_prefs).not_to be_nil,
                                'FakeProvider received no tool_prefs — translator dropped tool_choice'
      expect(tool_prefs[:choice]).to eq(:bash).or eq('bash')
    end
  end

  describe '/v1/chat/completions — openai tool_choice' do
    it 'threads body.tool_choice to FakeProvider as tool_prefs' do
      FakeProvider.with_scenario(:tool_single) do
        post '/v1/chat/completions',
             Legion::JSON.dump({
                                 model:       'fake-default',
                                 messages:    [{ role: 'user', content: 'list files' }],
                                 tools:       [{ type:     'function',
                                                 function: { name: 'bash', description: 'run',
parameters: { type: 'object', properties: { command: { type: 'string' } }, required: %w[command] } } }],
                                 tool_choice: { type: 'function', function: { name: 'bash' } }
                               }),
             'CONTENT_TYPE' => 'application/json'
      end

      expect(last_response.status).to eq(200)

      call = FakeProvider.calls.last
      expect(call).not_to be_nil
      tool_prefs = call[:tool_prefs]
      expect(tool_prefs).not_to be_nil,
                                'FakeProvider received no tool_prefs — translator dropped tool_choice'
      expect(tool_prefs[:choice]).to eq(:bash).or eq('bash')
    end
  end
end
