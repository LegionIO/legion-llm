# frozen_string_literal: true

# G23 — In-process matrix harness for /v1/responses (OpenAI Responses API).
#
# Mirrors the legionio-e2e codex/* and codex/responses/* scenarios but runs
# in-process against the deterministic FakeProvider. Asserts what
# CodexValidate validates: status (completed | requires_action), output[]
# items (message / function_call / message+phase=reasoning), tool_call counts
# and call_id presence, usage shape, SSE event types and the terminal
# response.completed/response.done event.

require_relative 'matrix_helper'

RSpec.describe '[matrix] /v1/responses (OpenAI Responses) × FakeProvider', type: :request do
  include Rack::Test::Methods

  let(:app) { MatrixHelper.app_class }

  before do
    MatrixHelper.configure_for_fake!
  end

  after do
    MatrixHelper.restore_started_state!
  end

  def post_responses(**body)
    post '/v1/responses', Legion::JSON.dump(body), 'CONTENT_TYPE' => 'application/json'
    last_response
  end

  describe 'scenario: text (hello_ping)' do
    it 'returns object=response, status=completed, exactly 1 message item, no function_call' do
      FakeProvider.with_scenario(:text) do
        resp = post_responses(model: 'fake-default', input: 'Say hello.')
        expect(resp.status).to eq(200)
        body = Legion::JSON.load(resp.body)
        expect(body[:object]).to eq('response')
        expect(body[:status]).to eq('completed')
        message_items = body[:output].select { |i| i[:type] == 'message' }
        expect(message_items.size).to eq(1)
        # The message item carries one output_text content block.
        text_blocks = message_items.first[:content].select { |c| c[:type] == 'output_text' }
        expect(text_blocks.size).to eq(1)
        expect(text_blocks.first[:text]).to eq('Hello there.')

        function_calls = body[:output].select { |i| i[:type] == 'function_call' }
        expect(function_calls).to be_empty

        expect(body[:usage][:input_tokens]).to be_a(Integer)
        expect(body[:usage][:output_tokens]).to be_a(Integer)
        expect(body[:usage][:total_tokens]).to eq(body[:usage][:input_tokens] + body[:usage][:output_tokens])
      end
    end
  end

  describe 'scenario: reasoning (hello_ping_reasoning)' do
    # CodexValidate.validate_responses_reasoning accepts EITHER:
    #   - a `message` output item tagged `phase: 'reasoning'` with output_text content, OR
    #   - usage.output_tokens_details.reasoning_tokens > 0
    # The 172c756 fix (HEAD) emits the message+phase shape; the previous
    # `type: 'thinking'` shape this regression test guards against would FAIL
    # both validator branches because (a) it isn't a message+phase=reasoning
    # item and (b) we don't synthesize reasoning_tokens.
    it 'emits reasoning as a message output item with phase=reasoning carrying output_text' do
      FakeProvider.with_scenario(:thinking) do
        resp = post_responses(model: 'fake-default', input: 'What is 2+2?',
                              reasoning: { effort: 'high' })
        expect(resp.status).to eq(200)
        body = Legion::JSON.load(resp.body)
        reasoning_messages = body[:output].select do |i|
          i[:type] == 'message' && i[:phase] == 'reasoning'
        end
        expect(reasoning_messages.size).to eq(1)
        text_blocks = reasoning_messages.first[:content].select { |c| c[:type] == 'output_text' }
        expect(text_blocks).not_to be_empty
        total = text_blocks.sum { |c| c[:text].length }
        expect(total).to be > 0

        # No `type: 'thinking'` items should leak through (the 172c756 regression).
        expect(body[:output].any? { |i| i[:type] == 'thinking' }).to be(false)
      end
    end
  end

  describe 'scenario: tool_single' do
    it 'returns exactly 1 function_call item with status=requires_action and a call_id' do
      FakeProvider.with_scenario(:tool_single) do
        resp = post_responses(
          model: 'fake-default',
          input: [{ role: 'user', content: 'Run: ls -la' }],
          tools: [{ type: 'function', name: 'bash', parameters: { type: 'object' } }]
        )
        expect(resp.status).to eq(200)
        body = Legion::JSON.load(resp.body)
        function_calls = body[:output].select { |i| i[:type] == 'function_call' }
        expect(function_calls.size).to eq(1)
        expect(function_calls.first[:name]).to eq('bash')
        expect(function_calls.first[:call_id]).not_to be_nil
        expect(function_calls.first[:arguments]).to be_a(String)
        expect(body[:status]).to eq('requires_action')
      end
    end
  end

  describe 'scenario: tool_parallel_same_name' do
    it 'returns exactly 2 function_call items with the same name and distinct call_ids' do
      FakeProvider.with_scenario(:tool_parallel_same_name) do
        resp = post_responses(
          model: 'fake-default',
          input: [{ role: 'user', content: 'parallel' }],
          tools: [{ type: 'function', name: 'bash', parameters: { type: 'object' } }]
        )
        body = Legion::JSON.load(resp.body)
        function_calls = body[:output].select { |i| i[:type] == 'function_call' }
        expect(function_calls.size).to eq(2)
        expect(function_calls.map { |c| c[:name] }.uniq).to eq(['bash'])
        expect(function_calls.map { |c| c[:call_id] }.uniq.size).to eq(2)
        expect(body[:status]).to eq('requires_action')
      end
    end
  end

  describe 'scenario: multi_turn_continuation (function_call_output)' do
    # cb7a08b regression: the Responses input normalizer emits flat tool_call
    # hashes (id/name/arguments at the top level) so Canonical::Message and
    # Inference::Request preserve tool_call_id+name on the assistant turn.
    # The multi-turn payload exercises the same parse path: function_call →
    # function_call_output → user. If the cb7a08b shape regresses, the
    # assistant turn loses tool_call_id and the FakeProvider's multi_turn
    # response sees tool_messages == 0 and emits the wrong text.
    it 'completes with the second-turn text after a function_call_output is supplied' do
      FakeProvider.with_scenario(:multi_turn_continuation) do
        resp = post_responses(
          model: 'fake-default',
          input: [
            { role: 'user', content: 'Run ls.' },
            { type: 'function_call', call_id: 'fc_1', name: 'bash', arguments: '{"command":"ls"}' },
            { type: 'function_call_output', call_id: 'fc_1', output: 'a.txt b.txt' }
          ]
        )
        expect(resp.status).to eq(200)
        body = Legion::JSON.load(resp.body)
        message_items = body[:output].select { |i| i[:type] == 'message' && i[:phase] != 'reasoning' }
        text_blocks = message_items.first[:content].select { |c| c[:type] == 'output_text' }
        expect(text_blocks.first[:text]).to include('Files listed')
        expect(body[:status]).to eq('completed')
      end
    end
  end

  describe 'scenario: streaming text' do
    it 'emits response.created → in_progress → output_text.delta → response.completed' do
      FakeProvider.with_scenario(:stream_text) do
        resp = post_responses(model: 'fake-default', stream: true,
                              input: [{ role: 'user', content: 'hi' }])
        expect(resp.status).to eq(200)
        events = MatrixHelper.parse_sse(resp.body)
        types = MatrixHelper.sse_responses_types(events)
        expect(types.first).to eq('response.created')
        expect(types).to include('response.in_progress')
        expect(types).to include('response.output_item.added')
        expect(types).to include('response.output_text.delta')
        expect(types).to include('response.output_text.done')
        expect(types).to include('response.output_item.done')
        expect(types.last).to eq('response.completed')
      end
    end
  end

  describe 'scenario: streaming reasoning' do
    it 'emits response.thinking.delta and response.thinking.done before output_text events' do
      FakeProvider.with_scenario(:stream_thinking) do
        resp = post_responses(
          model: 'fake-default', stream: true,
          input: [{ role: 'user', content: 'think' }],
          reasoning: { effort: 'high' }
        )
        types = MatrixHelper.sse_responses_types(MatrixHelper.parse_sse(resp.body))
        expect(types).to include('response.thinking.delta')
        expect(types).to include('response.thinking.done')
        first_thinking = types.index('response.thinking.delta')
        first_text = types.index('response.output_text.delta')
        expect(first_thinking).to be < first_text if first_text
      end
    end
  end

  describe 'scenario: streaming tool_call' do
    it 'emits response.function_call_arguments.delta and a terminal requires_action response.done' do
      FakeProvider.with_scenario(:stream_tool) do
        resp = post_responses(
          model: 'fake-default', stream: true,
          input: [{ role: 'user', content: 'Run: ls -la' }],
          tools: [{ type: 'function', name: 'bash', parameters: { type: 'object' } }]
        )
        events = MatrixHelper.parse_sse(resp.body)
        types = MatrixHelper.sse_responses_types(events)
        expect(types).to include('response.output_item.added')
        expect(types).to include('response.function_call_arguments.delta')
        expect(types).to include('response.function_call_arguments.done')
        expect(types.last).to eq('response.done')

        terminal = events.last[1]
        expect(terminal[:response][:status]).to eq('requires_action')
        function_calls = terminal.dig(:response, :output).select { |i| i[:type] == 'function_call' }
        expect(function_calls.size).to eq(1)
      end
    end
  end

  describe 'error paths' do
    it 'returns a 400 on missing input' do
      resp = post_responses(model: 'fake-default')
      expect(resp.status).to eq(400)
      body = Legion::JSON.load(resp.body)
      expect(body[:error][:type]).to eq('invalid_request_error')
    end

    it 'maps provider errors to a 502 server_error' do
      FakeProvider.with_scenario(:error) do
        resp = post_responses(model: 'fake-default', input: 'fail')
        expect(resp.status).to eq(502)
        body = Legion::JSON.load(resp.body)
        expect(body[:error][:type]).to eq('server_error')
      end
    end
  end
end
