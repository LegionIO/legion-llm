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

  shared_examples 'mixed failed LegionIO tool result plus client passthrough tool' do |client_format|
    it "keeps server failure visible and client passthrough actionable for #{client_format}" do
      MatrixHelper.register_legion_failure_tool!

      FakeProvider.with_scenario(:server_tool_failure_with_client_passthrough) do
        case client_format
        when :anthropic_messages
          post '/v1/messages',
               Legion::JSON.dump({
                                   model:      'fake-default',
                                   max_tokens: 1024,
                                   messages:   [{ role: 'user', content: 'try a server tool and a client tool' }],
                                   tools:      [
                                     {
                                       name:         'exec_command',
                                       description:  'Run a local command in the client.',
                                       input_schema: {
                                         type:       'object',
                                         properties: { cmd: { type: 'string' } },
                                         required:   %w[cmd]
                                       }
                                     }
                                   ]
                                 }),
               'CONTENT_TYPE' => 'application/json'
        when :openai_responses
          post '/v1/responses',
               Legion::JSON.dump({
                                   model: 'fake-default',
                                   input: 'try a server tool and a client tool',
                                   tools: [
                                     {
                                       type:        'function',
                                       name:        'exec_command',
                                       description: 'Run a local command in the client.',
                                       parameters:  {
                                         type:       'object',
                                         properties: { cmd: { type: 'string' } },
                                         required:   %w[cmd]
                                       }
                                     }
                                   ]
                                 }),
               'CONTENT_TYPE' => 'application/json'
        when :openai_chat
          post '/v1/chat/completions',
               Legion::JSON.dump({
                                   model:    'fake-default',
                                   messages: [{ role: 'user', content: 'try a server tool and a client tool' }],
                                   tools:    [
                                     {
                                       type:     'function',
                                       function: {
                                         name:        'exec_command',
                                         description: 'Run a local command in the client.',
                                         parameters:  {
                                           type:       'object',
                                           properties: { cmd: { type: 'string' } },
                                           required:   %w[cmd]
                                         }
                                       }
                                     }
                                   ]
                                 }),
               'CONTENT_TYPE' => 'application/json'
        else
          raise "unknown client_format=#{client_format.inspect}"
        end
      end

      expect(last_response.status).to eq(200), -> { "got #{last_response.status}: #{last_response.body[0, 500]}" }
      body = Legion::JSON.load(last_response.body)

      case client_format
      when :anthropic_messages
        content = body[:content]
        server_use = content.find { |item| item[:type] == 'server_tool_use' && item[:name] == 'fake_legion_failure' }
        server_result = content.find { |item| item[:type] == 'server_tool_result' }
        client_use = content.find { |item| item[:type] == 'tool_use' && item[:name] == 'exec_command' }

        expect(server_use).not_to be_nil
        expect(server_result).not_to be_nil
        expect(server_result.dig(:content, 0, :text)).to include('deterministic fake LegionIO tool failure')
        expect(client_use).not_to be_nil
        expect(body[:stop_reason]).to eq('tool_use')
      when :openai_responses
        output = body[:output]
        server_call = output.find { |item| item[:type] == 'function_call' && item[:name] == 'fake_legion_failure' }
        server_result = output.find { |item| item[:type] == 'function_call_output' && item[:call_id] == 'call_fake_legion_bad' }
        client_call = output.find { |item| item[:type] == 'function_call' && item[:name] == 'exec_command' }

        expect(server_call).not_to be_nil
        expect(server_call[:status]).to eq('completed')
        expect(server_result).not_to be_nil
        expect(server_result[:output]).to include('deterministic fake LegionIO tool failure')
        expect(client_call).not_to be_nil
        # Responses protocol: the pending client call rides in output[] as a
        # function_call item; the response status is `completed` (the client
        # executes it and continues via function_call_output). No requires_action.
        expect(body[:status]).to eq('completed')
      when :openai_chat
        choice = body[:choices].first
        message = choice[:message]
        server_text = message[:content].to_s
        client_tool_calls = message[:tool_calls] || []

        expect(server_text).to include('deterministic fake LegionIO tool failure')
        expect(choice[:finish_reason]).to eq('tool_calls')
        expect(client_tool_calls.map { |item| item.dig(:function, :name) }).to include('exec_command')
        expect(client_tool_calls.map { |item| item.dig(:function, :name) }).not_to include('fake_legion_failure')
      end
    ensure
      MatrixHelper.unregister_legion_failure_tool!
    end
  end

  describe 'mixed failed LegionIO tool result plus client passthrough tool' do
    include_examples 'mixed failed LegionIO tool result plus client passthrough tool', :anthropic_messages
    include_examples 'mixed failed LegionIO tool result plus client passthrough tool', :openai_responses
    include_examples 'mixed failed LegionIO tool result plus client passthrough tool', :openai_chat
  end

  # TOOLS ROOT-2 / G24 execution-proxy invariant (offline oracle for the
  # spec/claude/vllm/{tool_call, tool_call_multi_turn, thinking_not_empty_response}
  # regressions and the codex siblings). A PURE client-declared tool call, and
  # the provider reports stop_reason :end_turn (the captured vLLM/qwen shape).
  # A client-actionable call must exit PENDING: it renders as a pending tool_use
  # with stop_reason 'tool_use' (/v1/messages) and as an actionable function_call
  # with NO function_call_output sibling (/v1/responses) — the daemon must NOT
  # stamp a fabricated "Passthrough to client" result on it and must NOT let the
  # provider's :end_turn leak through. Before FIX 3 the /v1/messages cell renders
  # stop_reason 'end_turn' (the fabricated result defeats format_stop_reason).
  shared_examples 'pending client passthrough tool call with provider end_turn' do |client_format|
    it "renders a pending tool_use (never a fabricated result) for #{client_format}" do
      FakeProvider.with_scenario(:client_tool_passthrough_pending) do
        case client_format
        when :anthropic_messages
          post '/v1/messages',
               Legion::JSON.dump({
                                   model:      'fake-default',
                                   max_tokens: 1024,
                                   messages:   [{ role: 'user', content: 'run a client tool' }],
                                   tools:      [
                                     {
                                       name:         'exec_command',
                                       description:  'Run a local command in the client.',
                                       input_schema: {
                                         type:       'object',
                                         properties: { cmd: { type: 'string' } },
                                         required:   %w[cmd]
                                       }
                                     }
                                   ]
                                 }),
               'CONTENT_TYPE' => 'application/json'
        when :openai_responses
          post '/v1/responses',
               Legion::JSON.dump({
                                   model: 'fake-default',
                                   input: 'run a client tool',
                                   tools: [
                                     {
                                       type:        'function',
                                       name:        'exec_command',
                                       description: 'Run a local command in the client.',
                                       parameters:  {
                                         type:       'object',
                                         properties: { cmd: { type: 'string' } },
                                         required:   %w[cmd]
                                       }
                                     }
                                   ]
                                 }),
               'CONTENT_TYPE' => 'application/json'
        else
          raise "unknown client_format=#{client_format.inspect}"
        end
      end

      expect(last_response.status).to eq(200), -> { "got #{last_response.status}: #{last_response.body[0, 500]}" }
      body = Legion::JSON.load(last_response.body)

      case client_format
      when :anthropic_messages
        content = body[:content]
        client_use = content.find { |item| item[:type] == 'tool_use' && item[:name] == 'exec_command' }

        # A client-actionable call is a PENDING plain tool_use — never a
        # server_tool_use, and never accompanied by a (fabricated) server_tool_result.
        expect(client_use).not_to be_nil
        expect(content.map { |item| item[:type] }).not_to include('server_tool_use')
        expect(content.map { |item| item[:type] }).not_to include('server_tool_result')
        # The invariant: the pending client call wins the stop reason over the
        # provider's :end_turn. Before FIX 3 this is 'end_turn'.
        expect(body[:stop_reason]).to eq('tool_use')
      when :openai_responses
        output = body[:output]
        client_call = output.find { |item| item[:type] == 'function_call' && item[:name] == 'exec_command' }

        # Actionable client call rides in output[]; it must NOT be paired with a
        # function_call_output (that pairing is reserved for server-executed
        # tools — a fabricated passthrough result must never surface as one).
        expect(client_call).not_to be_nil
        expect(output.map { |item| item[:type] }).not_to include('function_call_output')
        expect(body[:status]).to eq('completed')
      end
    end
  end

  describe 'pending client passthrough tool call with provider end_turn' do
    include_examples 'pending client passthrough tool call with provider end_turn', :anthropic_messages
    include_examples 'pending client passthrough tool call with provider end_turn', :openai_responses
  end

  # Faithful vLLM reproduction: the provider translator does NOT stamp source
  # on response tool calls (source arrives nil). The executor must resolve
  # execution authority BY NAME (find_tool_source fallback) so a client tool
  # still surfaces as PENDING. Without the fallback, canonical_source_symbol(nil)
  # → nil → client_pending false → the tool inherits the "Passthrough to client"
  # placeholder result → format_stop_reason returns end_turn instead of tool_use.
  shared_examples 'pending client passthrough tool call (source nil from provider)' do |client_format|
    it "resolves source by name and renders pending tool_use for #{client_format}" do
      FakeProvider.with_scenario(:client_tool_passthrough_pending_source_nil) do
        case client_format
        when :anthropic_messages
          post '/v1/messages',
               Legion::JSON.dump({
                                   model:      'fake-default',
                                   max_tokens: 1024,
                                   messages:   [{ role: 'user', content: 'run a client tool [fake:client_tool_passthrough_pending_source_nil]' }],
                                   tools:      [
                                     {
                                       name:         'exec_command',
                                       description:  'Run a local command in the client.',
                                       input_schema: {
                                         type:       'object',
                                         properties: { cmd: { type: 'string' } },
                                         required:   %w[cmd]
                                       }
                                     }
                                   ]
                                 }),
               'CONTENT_TYPE' => 'application/json'
        when :openai_responses
          post '/v1/responses',
               Legion::JSON.dump({
                                   model: 'fake-default',
                                   input: 'run a client tool [fake:client_tool_passthrough_pending_source_nil]',
                                   tools: [
                                     {
                                       type:        'function',
                                       name:        'exec_command',
                                       description: 'Run a local command in the client.',
                                       parameters:  {
                                         type:       'object',
                                         properties: { cmd: { type: 'string' } },
                                         required:   %w[cmd]
                                       }
                                     }
                                   ]
                                 }),
               'CONTENT_TYPE' => 'application/json'
        else
          raise "unknown client_format=#{client_format.inspect}"
        end
      end

      expect(last_response.status).to eq(200), -> { "got #{last_response.status}: #{last_response.body[0, 500]}" }
      body = Legion::JSON.load(last_response.body)

      case client_format
      when :anthropic_messages
        content = body[:content]
        client_use = content.find { |item| item[:type] == 'tool_use' && item[:name] == 'exec_command' }

        # A client-actionable call is PENDING plain tool_use — no server shapes,
        # no fabricated result.
        expect(client_use).not_to be_nil
        expect(content.map { |item| item[:type] }).not_to include('server_tool_use')
        expect(content.map { |item| item[:type] }).not_to include('server_tool_result')
        # The invariant: the pending client call wins the stop reason.
        expect(body[:stop_reason]).to eq('tool_use')
      when :openai_responses
        output = body[:output]
        client_call = output.find { |item| item[:type] == 'function_call' && item[:name] == 'exec_command' }

        # Actionable client call rides in output[]; no function_call_output
        # (fabricated passthrough result must never surface as one).
        expect(client_call).not_to be_nil
        expect(output.map { |item| item[:type] }).not_to include('function_call_output')
        expect(body[:status]).to eq('completed')
      end
    end
  end

  describe 'pending client passthrough tool call (source nil from provider)' do
    include_examples 'pending client passthrough tool call (source nil from provider)', :anthropic_messages
    include_examples 'pending client passthrough tool call (source nil from provider)', :openai_responses
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
      followup_roles = followup[:messages].map do |message|
        (message.respond_to?(:role) ? message.role : (message[:role] || message['role'])).to_s
      end
      expect(followup_roles).to include('tool')
      tool_msg = followup[:messages].find do |message|
        (message.respond_to?(:role) ? message.role : (message[:role] || message['role'])).to_s == 'tool'
      end
      tool_content = if tool_msg.respond_to?(:content)
                       tool_msg.content.to_s
                     else
                       (tool_msg[:content] || tool_msg['content']).to_s
                     end
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
        role = (m.respond_to?(:role) ? m.role : (m[:role] || m['role'])).to_s
        content = m.respond_to?(:content) ? m.content : (m[:content] || m['content'])
        role == 'tool' && content.to_s.include?('echo:ping')
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
        role = (m.respond_to?(:role) ? m.role : (m[:role] || m['role'])).to_s
        content = m.respond_to?(:content) ? m.content : (m[:content] || m['content'])
        role == 'tool' && content.to_s.include?('echo:ping')
      end
      expect(tool_in_followup).to be(true)
    end
  end
end
