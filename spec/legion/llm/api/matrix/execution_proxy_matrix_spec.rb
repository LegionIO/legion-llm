# frozen_string_literal: true

# G23/G24 — In-process matrix harness for the LegionIO execution-proxy path.
#
# Asserts the IDENTICAL G24 shapes pinned by the lex-llm conformance kit:
# server-executed LegionIO tools surface as completed NON-actionable items
# on every client format. The kit's contract is the source of truth; this
# spec is the in-process gate; legionio-e2e's validators (claude+codex) run
# the same shape assertions live. Three suites, one oracle.
#
# G24 contract enforced here:
#   /v1/messages       → server_tool_use + server_tool_result blocks
#                        present, plain tool_use NOT present, stop_reason
#                        end_turn.
#   /v1/responses      → status 'completed' (NOT requires_action),
#                        completed function_call + function_call_output
#                        items present, action_required omitted, no
#                        non-completed function_call items.
#   /v1/chat/completions → finish_reason 'stop' (NOT 'tool_calls'),
#                        message.tool_calls absent or empty, server result
#                        text in assistant content.
#
# G24 provider-side assertion (point 1) — the FakeProvider's follow-up
# call MUST carry the tool result message back, proving the model "knows
# files changed" on next turn.

require_relative 'matrix_helper'

RSpec.describe '[matrix] execution-proxy path × FakeProvider', type: :request do
  include Rack::Test::Methods

  let(:app) { MatrixHelper.app_class }

  before do
    MatrixHelper.configure_for_fake!
    MatrixHelper.register_legion_tool!
  end

  after do
    MatrixHelper.unregister_legion_tool!
    MatrixHelper.restore_started_state!
  end

  describe '/v1/messages — server-side LegionIO tool execution' do
    it 'surfaces server_tool_use+server_tool_result and provider sees the tool result on next turn' do
      received_args = nil
      stub = MatrixHelper::FakeLegionEcho.singleton_class.prepend(Module.new do
        define_method(:call) do |**args|
          received_args = args
          super(**args)
        end
      end)
      _ = stub

      FakeProvider.with_scenario(:server_tool_legion) do
        post '/v1/messages',
             Legion::JSON.dump({
                                 model:      'fake-default',
                                 max_tokens: 1024,
                                 messages:   [{ role: 'user', content: 'list legionio tools' }]
                               }),
             'CONTENT_TYPE' => 'application/json'
      end

      expect(last_response.status).to eq(200)
      body = Legion::JSON.load(last_response.body)
      content = body[:content]

      # G24 point 1 — the tool actually executed server-side.
      expect(received_args).to eq(value: 'ping')

      # G24 point 1 (provider side) — the executor's follow-up call to the
      # provider must carry the tool result back. FakeProvider is invoked
      # twice: round 1 returns the tool_use, round 2 receives the messages
      # WITH the tool result and returns the final text.
      calls = FakeProvider.calls
      expect(calls.size).to be >= 2
      followup = calls[1]
      followup_roles = followup[:messages].map { |m| (m[:role] || m['role']).to_s }
      expect(followup_roles).to include('tool')
      tool_msg = followup[:messages].find { |m| (m[:role] || m['role']).to_s == 'tool' }
      tool_content = (tool_msg[:content] || tool_msg['content']).to_s
      expect(tool_content).to include('echo:ping')

      # G24 point 5 (round-trip — substring) — the LegionIO tool name
      # appears in the response, matching the legionio-e2e
      # validate_legionio_tools substring check.
      expect(last_response.body).to include('fake_legion_echo')

      # G24 point 2 (claude format) — server_tool_use + server_tool_result,
      # never plain tool_use; stop_reason end_turn.
      types = content.map { |b| b[:type] }
      expect(types).to include('server_tool_use')
      expect(types).to include('server_tool_result')
      expect(types).not_to include('tool_use')
      expect(body[:stop_reason]).to eq('end_turn')

      server_use = content.find { |b| b[:type] == 'server_tool_use' }
      expect(server_use[:name]).to eq('fake_legion_echo')
      expect(server_use[:input]).to eq(value: 'ping')

      server_result = content.find { |b| b[:type] == 'server_tool_result' }
      expect(server_result[:content].first[:text]).to include('echo:ping')

      # The follow-up assistant text from round 2 is also present.
      text_block = content.find { |b| b[:type] == 'text' }
      expect(text_block[:text]).to include('tool result observed: ping')
    end
  end

  describe '/v1/responses — server-side LegionIO tool execution' do
    it 'surfaces completed function_call+function_call_output items, status completed, no requires_action' do
      FakeProvider.with_scenario(:server_tool_legion) do
        post '/v1/responses',
             Legion::JSON.dump({ model: 'fake-default', input: 'list legionio tools' }),
             'CONTENT_TYPE' => 'application/json'
      end

      expect(last_response.status).to eq(200)
      body = Legion::JSON.load(last_response.body)

      # G24 point 3 (codex format) — completed status, no action_required.
      expect(body[:status]).to eq('completed')
      expect(body[:action_required]).to be_nil

      # Server tools surface as completed function_call items (visible to
      # the model+client) plus a function_call_output sibling carrying the
      # result. Never as 'in_progress' or 'requires_action' — the client
      # must not re-execute.
      function_calls = body[:output].select { |i| i[:type] == 'function_call' }
      expect(function_calls).not_to be_empty
      function_calls.each do |fc|
        expect(fc[:status]).to eq('completed'),
                               "function_call should be completed, got #{fc.inspect}"
        expect(fc[:name]).to eq('fake_legion_echo')
      end

      function_call_outputs = body[:output].select { |i| i[:type] == 'function_call_output' }
      expect(function_call_outputs).not_to be_empty
      function_call_outputs.each do |fco|
        expect(fco[:output].to_s).to include('echo:ping')
      end

      # Trailing assistant text from round 2 is also present.
      message_items = body[:output].select { |i| i[:type] == 'message' && i[:phase] != 'reasoning' }
      text = message_items.flat_map { |m| m[:content] }
                          .select { |c| c[:type] == 'output_text' }
                          .map { |c| c[:text] }
                          .join
      expect(text).to include('tool result observed: ping')

      # G24 point 1 — provider received the tool result on the follow-up.
      calls = FakeProvider.calls
      expect(calls.size).to be >= 2
      tool_in_followup = calls[1][:messages].any? do |m|
        role = (m[:role] || m['role']).to_s
        role == 'tool' && (m[:content] || m['content']).to_s.include?('echo:ping')
      end
      expect(tool_in_followup).to be(true)
    end
  end

  describe '/v1/chat/completions — server-side LegionIO tool execution' do
    it 'surfaces finish_reason stop with no actionable tool_calls; assistant text carries the result' do
      FakeProvider.with_scenario(:server_tool_legion) do
        post '/v1/chat/completions',
             Legion::JSON.dump({
                                 model:    'fake-default',
                                 messages: [{ role: 'user', content: 'list legionio tools' }]
                               }),
             'CONTENT_TYPE' => 'application/json'
      end

      expect(last_response.status).to eq(200)
      body = Legion::JSON.load(last_response.body)

      choice = body[:choices].first
      # G24 point 3 (chat completions) — finish_reason 'stop' (NOT
      # 'tool_calls') because the only tool was server-resolved.
      expect(choice[:finish_reason]).to eq('stop')

      message = choice[:message]
      tool_calls = message[:tool_calls] || []
      expect(tool_calls).to be_empty

      # The assistant content carries the round-2 follow-up text.
      content = message[:content].to_s
      expect(content).to include('tool result observed: ping')

      # G24 point 1 — provider received the tool result on the follow-up.
      calls = FakeProvider.calls
      expect(calls.size).to be >= 2
      tool_in_followup = calls[1][:messages].any? do |m|
        role = (m[:role] || m['role']).to_s
        role == 'tool' && (m[:content] || m['content']).to_s.include?('echo:ping')
      end
      expect(tool_in_followup).to be(true)
    end
  end
end
