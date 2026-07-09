# frozen_string_literal: true

# In-process matrix harness for the leaked chat-template tool-call token
# (native_tool_loop pattern 4). Some models (gemma via vLLM, live capture
# ledger 2026-07) emit tool-call intent as a RAW token in content instead of
# the structured tool_calls field:
#
#   <|tool_call>call:NAME{key:<|"|>value<|"|>,...}<tool_call|>
#
# The executor must synthesize this into a real tool call (pattern 4), execute
# the LegionIO tool server-side, and — the whole point — NEVER surface the raw
# token to the client on any format. This closes the class, not one cell:
# /v1/messages, /v1/responses, /v1/chat/completions all asserted.
#
# The FakeProvider :tool_leaked_token scenario returns the leaked token as
# content with empty tool_calls on round 1, then plain text on round 2 — the
# exact production shape. It names fake_legion_echo (a registered server tool)
# so a correctly synthesized call executes server-side and the outcome matches
# the structured server_tool_legion path.

require_relative 'matrix_helper'

RSpec.describe '[matrix] leaked tool-call token synthesis × FakeProvider', type: :request do
  include Rack::Test::Methods

  # Raw token markers that must never reach the client.
  let(:leaked_markers) { ['<|tool_call>', '<tool_call|>', '<|"|>'] }

  let(:app) { MatrixHelper.app_class }

  before do
    MatrixHelper.configure_for_fake!
    MatrixHelper.register_legion_tool!
    Thread.current[:fake_leaked_token_round] = 0
  end

  after do
    MatrixHelper.unregister_legion_tool!
    MatrixHelper.restore_started_state!
    Thread.current[:fake_leaked_token_round] = 0
  end

  it '/v1/messages — synthesizes the leaked token into a server tool, no raw markers' do
    FakeProvider.with_scenario(:tool_leaked_token) do
      post '/v1/messages',
           Legion::JSON.dump({ model: 'fake-default', max_tokens: 1024,
                               messages: [{ role: 'user', content: 'do the thing' }] }),
           'CONTENT_TYPE' => 'application/json'
    end

    expect(last_response.status).to eq(200), -> { "got #{last_response.status}: #{last_response.body[0, 500]}" }
    body = Legion::JSON.load(last_response.body)

    # The raw token never reaches the client.
    leaked_markers.each { |m| expect(last_response.body).not_to include(m) }

    # It became a server_tool_use + server_tool_result (executed server-side),
    # exactly like a structured tool call would.
    types = body[:content].map { |b| b[:type] }
    expect(types).to include('server_tool_use')
    expect(types).to include('server_tool_result')
    server_use = body[:content].find { |b| b[:type] == 'server_tool_use' }
    expect(server_use[:name]).to eq('fake_legion_echo')
    expect(server_use[:input]).to eq(value: 'ping')
    server_result = body[:content].find { |b| b[:type] == 'server_tool_result' }
    expect(server_result[:content].first[:text]).to include('echo:ping')
  end

  it '/v1/responses — synthesizes the leaked token into a completed function_call, no raw markers' do
    FakeProvider.with_scenario(:tool_leaked_token) do
      post '/v1/responses',
           Legion::JSON.dump({ model: 'fake-default', input: 'do the thing' }),
           'CONTENT_TYPE' => 'application/json'
    end

    expect(last_response.status).to eq(200), -> { "got #{last_response.status}: #{last_response.body[0, 500]}" }
    body = Legion::JSON.load(last_response.body)

    leaked_markers.each { |m| expect(last_response.body).not_to include(m) }

    expect(body[:status]).to eq('completed')
    function_calls = body[:output].select { |i| i[:type] == 'function_call' }
    expect(function_calls).not_to be_empty
    function_calls.each do |fc|
      expect(fc[:status]).to eq('completed')
      expect(fc[:name]).to eq('fake_legion_echo')
    end
    outputs = body[:output].select { |i| i[:type] == 'function_call_output' }
    expect(outputs).not_to be_empty
    outputs.each { |fco| expect(fco[:output].to_s).to include('echo:ping') }
  end

  it '/v1/chat/completions — synthesizes the leaked token; finish_reason stop, no raw markers' do
    FakeProvider.with_scenario(:tool_leaked_token) do
      post '/v1/chat/completions',
           Legion::JSON.dump({ model:    'fake-default',
                               messages: [{ role: 'user', content: 'do the thing' }] }),
           'CONTENT_TYPE' => 'application/json'
    end

    expect(last_response.status).to eq(200), -> { "got #{last_response.status}: #{last_response.body[0, 500]}" }
    body = Legion::JSON.load(last_response.body)

    leaked_markers.each { |m| expect(last_response.body).not_to include(m) }

    choice = body[:choices].first
    # Server-resolved tool → finish_reason stop, no actionable tool_calls.
    expect(choice[:finish_reason]).to eq('stop')
    expect(choice[:message][:tool_calls] || []).to be_empty
    expect(choice[:message][:content].to_s).to include('tool result observed: echo:ping')
  end
end
