# frozen_string_literal: true

# G23 — In-process matrix harness for /v1/chat/completions.
#
# Mirrors the legionio-e2e codex/* chat completions scenarios. Asserts what
# CodexValidate.validate_response validates: object=chat.completion, choices,
# finish_reason in {stop, tool_calls, ...}, usage totals, tool_calls shape,
# and the SSE [DONE] terminator + chunk envelope.

require_relative 'matrix_helper'

RSpec.describe '[matrix] /v1/chat/completions × FakeProvider', type: :request do
  include Rack::Test::Methods

  let(:app) { MatrixHelper.app_class }

  before do
    MatrixHelper.configure_for_fake!
  end

  after do
    MatrixHelper.restore_started_state!
  end

  def post_chat(**body)
    post '/v1/chat/completions', Legion::JSON.dump(body), 'CONTENT_TYPE' => 'application/json'
    last_response
  end

  describe 'scenario: text (hello_ping)' do
    it 'returns object=chat.completion, finish_reason=stop, total_tokens consistent' do
      FakeProvider.with_scenario(:text) do
        resp = post_chat(model: 'fake-default', messages: [{ role: 'user', content: 'hi' }])
        expect(resp.status).to eq(200)
        body = Legion::JSON.load(resp.body)
        expect(body[:object]).to eq('chat.completion')
        choice = body[:choices].first
        expect(choice[:index]).to eq(0)
        expect(choice[:message][:role]).to eq('assistant')
        expect(choice[:message][:content]).to eq('Hello there.')
        expect(choice[:finish_reason]).to eq('stop')

        usage = body[:usage]
        expect(usage[:total_tokens]).to eq(usage[:prompt_tokens] + usage[:completion_tokens])
      end
    end
  end

  describe 'scenario: tool_single' do
    it 'returns finish_reason=tool_calls and exactly 1 tool_call entry' do
      FakeProvider.with_scenario(:tool_single) do
        resp = post_chat(
          model:    'fake-default',
          messages: [{ role: 'user', content: 'Run: ls -la' }],
          tools:    [{
            type:     'function',
            function: { name:       'bash',
                        parameters: { type: 'object', properties: { command: { type: 'string' } }, required: ['command'] } }
          }]
        )
        body = Legion::JSON.load(resp.body)
        choice = body[:choices].first
        expect(choice[:finish_reason]).to eq('tool_calls')
        tool_calls = choice[:message][:tool_calls]
        expect(tool_calls.size).to eq(1)
        expect(tool_calls.first[:type]).to eq('function')
        expect(tool_calls.first[:function][:name]).to eq('bash')
        expect(tool_calls.first[:function][:arguments]).to be_a(String)
      end
    end
  end

  describe 'scenario: tool_parallel_same_name' do
    it 'returns 2 tool_calls with the same name and distinct ids' do
      FakeProvider.with_scenario(:tool_parallel_same_name) do
        resp = post_chat(
          model:    'fake-default',
          messages: [{ role: 'user', content: 'parallel' }],
          tools:    [{ type:     'function',
                       function: { name: 'bash', parameters: { type: 'object' } } }]
        )
        body = Legion::JSON.load(resp.body)
        tool_calls = body[:choices].first[:message][:tool_calls]
        expect(tool_calls.size).to eq(2)
        expect(tool_calls.map { |c| c[:function][:name] }.uniq).to eq(['bash'])
        expect(tool_calls.map { |c| c[:id] }.uniq.size).to eq(2)
      end
    end
  end

  describe 'scenario: streaming text' do
    it 'emits chat.completion.chunk frames and a final data: [DONE] terminator' do
      FakeProvider.with_scenario(:stream_text) do
        resp = post_chat(model: 'fake-default', stream: true,
                         messages: [{ role: 'user', content: 'hi' }])
        expect(resp.status).to eq(200)
        expect(resp.body).to include('data: [DONE]')

        events = MatrixHelper.parse_sse(resp.body)
        json_chunks = events.filter_map { |(_name, data)| data if data.is_a?(Hash) }
        expect(json_chunks).not_to be_empty
        expect(json_chunks.first[:object]).to eq('chat.completion.chunk')
        expect(json_chunks.first[:choices][0][:delta]).to be_a(Hash)
        # Some chunk delivered text content.
        text_deltas = json_chunks.flat_map { |c| c[:choices].map { |ch| ch[:delta][:content] } }.compact
        expect(text_deltas.join).to eq('Hello there.')
      end
    end
  end

  describe 'scenario: streaming tool_call' do
    it 'emits tool_calls deltas and a final chunk with finish_reason=tool_calls' do
      FakeProvider.with_scenario(:stream_tool) do
        resp = post_chat(
          model: 'fake-default', stream: true,
          messages: [{ role: 'user', content: 'Run: ls -la' }],
          tools: [{ type:     'function',
                    function: { name: 'bash', parameters: { type: 'object' } } }]
        )
        events = MatrixHelper.parse_sse(resp.body)
        json_chunks = events.filter_map { |(_name, data)| data if data.is_a?(Hash) }
        # At least one chunk carries tool_calls.
        tool_chunks = json_chunks.select do |c|
          c[:choices].any? { |ch| ch[:delta][:tool_calls] }
        end
        expect(tool_chunks).not_to be_empty
        finish_chunks = json_chunks.select do |c|
          c[:choices].any? { |ch| ch[:finish_reason] }
        end
        expect(finish_chunks.last[:choices][0][:finish_reason]).to eq('tool_calls')
      end
    end
  end

  describe 'error paths' do
    it 'returns a 400 on missing messages' do
      resp = post_chat(model: 'fake-default')
      expect(resp.status).to eq(400)
      body = Legion::JSON.load(resp.body)
      expect(body[:error][:type]).to eq('invalid_request_error')
    end

    it 'maps an exhausted provider error to a retriable 503 server_error (SSOT: no lane left)' do
      FakeProvider.with_scenario(:error) do
        resp = post_chat(model: 'fake-default', messages: [{ role: 'user', content: 'fail' }])
        # SSOT single engine: a retriable provider error consumes the only lane;
        # next_lane then has no eligible target -> service_unavailable (503+Retry-After),
        # not the legacy immediate 502. Retriable, self-clearing on provider readiness.
        expect(resp.status).to eq(503)
        body = Legion::JSON.load(resp.body)
        expect(body[:error][:type]).to eq('server_error')
      end
    end
  end
end
