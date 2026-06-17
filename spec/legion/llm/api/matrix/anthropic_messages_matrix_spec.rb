# frozen_string_literal: true

# G23 — In-process matrix harness for /v1/messages (Anthropic Messages API).
#
# Mirrors the legionio-e2e claude/* scenarios but runs in-process against a
# deterministic FakeProvider. Asserts the same things the live e2e validator
# asserts: status, response shape, exact tool_use COUNTS, thinking presence,
# stop_reason semantics, SSE event sequences. No network, no AMQP, no daemon.

require_relative 'matrix_helper'

RSpec.describe '[matrix] /v1/messages (Anthropic) × FakeProvider', type: :request do
  include Rack::Test::Methods

  let(:app) { MatrixHelper.app_class }

  before do
    MatrixHelper.configure_for_fake!
  end

  after do
    MatrixHelper.restore_started_state!
  end

  def post_messages(**payload)
    post '/v1/messages', Legion::JSON.dump(payload), { 'CONTENT_TYPE' => 'application/json' }
    last_response
  end

  describe 'scenario: text (hello_ping)' do
    it 'returns a valid Anthropic message with one text content block and stop_reason=end_turn' do
      FakeProvider.with_scenario(:text) do
        resp = post_messages(model:      'fake-default',
                             messages:   [{ role: 'user', content: 'Say hello.' }],
                             max_tokens: 64)
        expect(resp.status).to eq(200)
        body = Legion::JSON.load(resp.body)
        expect(body[:type]).to eq('message')
        expect(body[:role]).to eq('assistant')
        expect(body[:content]).to be_an(Array)
        text_blocks = body[:content].select { |b| b[:type] == 'text' }
        expect(text_blocks.size).to eq(1)
        expect(text_blocks.first[:text]).to eq('Hello there.')
        expect(body[:stop_reason]).to eq('end_turn')
        expect(body[:usage][:input_tokens]).to be_a(Integer)
        expect(body[:usage][:output_tokens]).to be_a(Integer)
      end
    end
  end

  describe 'scenario: thinking' do
    it 'surfaces a thinking content block before the text block' do
      FakeProvider.with_scenario(:thinking) do
        resp = post_messages(
          model:      'fake-default',
          max_tokens: 1024,
          thinking:   { type: 'enabled', budget_tokens: 512 },
          messages:   [{ role: 'user', content: 'What is 2 + 2?' }]
        )
        expect(resp.status).to eq(200)
        body = Legion::JSON.load(resp.body)
        types = body[:content].map { |b| b[:type] }
        expect(types).to include('thinking')
        thinking_block = body[:content].find { |b| b[:type] == 'thinking' }
        expect(thinking_block[:thinking]).to be_a(String)
        expect(thinking_block[:thinking]).not_to be_empty
        expect(types.last).to eq('text')
        expect(body[:stop_reason]).to eq('end_turn')
      end
    end
  end

  describe 'scenario: tool_single' do
    it 'returns exactly 1 tool_use block with stop_reason=tool_use' do
      FakeProvider.with_scenario(:tool_single) do
        resp = post_messages(
          model:      'fake-default',
          max_tokens: 1024,
          messages:   [{ role: 'user', content: 'Run: ls -la' }],
          tools:      [{ name: 'bash', description: 'shell', input_schema: { type: 'object' } }]
        )
        expect(resp.status).to eq(200)
        body = Legion::JSON.load(resp.body)
        tool_uses = body[:content].select { |b| b[:type] == 'tool_use' }
        expect(tool_uses.size).to eq(1)
        expect(tool_uses.first[:name]).to eq('bash')
        expect(tool_uses.first[:input]).to be_a(Hash)
        expect(body[:stop_reason]).to eq('tool_use')
      end
    end
  end

  describe 'scenario: tool_parallel_same_name' do
    it 'returns exactly 2 tool_use blocks with the same name and distinct ids' do
      FakeProvider.with_scenario(:tool_parallel_same_name) do
        resp = post_messages(
          model:      'fake-default',
          max_tokens: 1024,
          messages:   [{ role: 'user', content: 'Run ls and pwd in parallel.' }],
          tools:      [{ name: 'bash', description: 'shell', input_schema: { type: 'object' } }]
        )
        expect(resp.status).to eq(200)
        body = Legion::JSON.load(resp.body)
        tool_uses = body[:content].select { |b| b[:type] == 'tool_use' }
        expect(tool_uses.size).to eq(2)
        expect(tool_uses.map { |t| t[:name] }.uniq).to eq(['bash'])
        expect(tool_uses.map { |t| t[:id] }.uniq.size).to eq(2)
      end
    end
  end

  describe 'scenario: multi_turn_continuation' do
    it 'continues with text after a tool_result is supplied' do
      FakeProvider.with_scenario(:multi_turn_continuation) do
        resp = post_messages(
          model:      'fake-default',
          max_tokens: 1024,
          messages:   [
            { role: 'user',      content: 'Run ls.' },
            { role: 'assistant', content: [{ type: 'tool_use', id: 'tu_1', name: 'bash', input: { command: 'ls' } }] },
            { role:    'user',
              content: [{ type: 'tool_result', tool_use_id: 'tu_1', content: 'a.txt b.txt' }] }
          ]
        )
        expect(resp.status).to eq(200)
        body = Legion::JSON.load(resp.body)
        text = body[:content].select { |b| b[:type] == 'text' }
        expect(text.size).to eq(1)
        expect(text.first[:text]).to include('Files listed')
        expect(body[:stop_reason]).to eq('end_turn')
      end
    end
  end

  describe 'scenario: streaming text' do
    it 'emits the SSE event sequence message_start → content_block_start/delta/stop → message_delta → message_stop' do
      FakeProvider.with_scenario(:stream_text) do
        resp = post_messages(model: 'fake-default', max_tokens: 64, stream: true,
                             messages: [{ role: 'user', content: 'hi' }])
        expect(resp.status).to eq(200)
        events = MatrixHelper.parse_sse(resp.body)
        names = MatrixHelper.sse_event_names(events)
        expect(names.first).to eq('message_start')
        expect(names).to include('content_block_start')
        expect(names).to include('content_block_delta')
        expect(names).to include('content_block_stop')
        expect(names).to include('message_delta')
        expect(names.last).to eq('message_stop')
        # Verify content_block_start precedes its corresponding delta.
        start_idx = names.index('content_block_start')
        delta_idx = names.index('content_block_delta')
        expect(start_idx).to be < delta_idx
      end
    end
  end

  describe 'scenario: streaming thinking' do
    it 'emits a thinking content block before the text block' do
      FakeProvider.with_scenario(:stream_thinking) do
        resp = post_messages(
          model:      'fake-default',
          max_tokens: 256,
          stream:     true,
          thinking:   { type: 'enabled', budget_tokens: 256 },
          messages:   [{ role: 'user', content: 'think then answer' }]
        )
        expect(resp.status).to eq(200)
        events = MatrixHelper.parse_sse(resp.body)
        # Find the first content_block_start event and inspect its payload.
        first_block = events.find { |(name, _)| name == 'content_block_start' }
        expect(first_block).not_to be_nil
        block_type = first_block[1].dig(:content_block, :type)
        expect(block_type).to eq('thinking')
      end
    end
  end

  describe 'scenario: streaming tool_call' do
    it 'emits a tool_use content_block_start with input_json deltas and stop_reason=tool_use' do
      FakeProvider.with_scenario(:stream_tool) do
        resp = post_messages(
          model:      'fake-default',
          max_tokens: 256,
          stream:     true,
          messages:   [{ role: 'user', content: 'Run: ls -la' }],
          tools:      [{ name: 'bash', description: 'shell', input_schema: { type: 'object' } }]
        )
        expect(resp.status).to eq(200)
        events = MatrixHelper.parse_sse(resp.body)
        names = MatrixHelper.sse_event_names(events)
        expect(names).to include('content_block_start')
        expect(names).to include('content_block_stop')

        tool_block_start = events.find do |(name, data)|
          name == 'content_block_start' && data.dig(:content_block, :type) == 'tool_use'
        end
        expect(tool_block_start).not_to be_nil
        expect(tool_block_start[1].dig(:content_block, :name)).to eq('bash')

        message_delta = events.find { |(name, _)| name == 'message_delta' }
        expect(message_delta[1].dig(:delta, :stop_reason)).to eq('tool_use')
      end
    end
  end

  describe 'error paths' do
    it 'returns a structured error body for missing required fields' do
      resp = post_messages(model: 'fake-default')
      expect(resp.status).to eq(400)
      body = Legion::JSON.load(resp.body)
      expect(body[:type]).to eq('error')
      expect(body[:error][:type]).to eq('invalid_request_error')
    end

    it 'maps provider errors to Anthropic 529 overloaded_error' do
      FakeProvider.with_scenario(:error) do
        resp = post_messages(model: 'fake-default', max_tokens: 64,
                             messages: [{ role: 'user', content: 'fail' }])
        expect(resp.status).to eq(529)
        body = Legion::JSON.load(resp.body)
        expect(body[:type]).to eq('error')
        expect(body[:error][:type]).to eq('overloaded_error')
      end
    end
  end
end
