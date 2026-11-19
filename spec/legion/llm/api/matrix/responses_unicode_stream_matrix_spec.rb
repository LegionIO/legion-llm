# frozen_string_literal: true

require 'net/http'
require 'stringio'
require_relative 'matrix_helper'

RSpec.describe '[matrix] Responses Unicode over HTTP byte streams', type: :request do
  include Rack::Test::Methods

  let(:app) { MatrixHelper.app_class }
  let(:unicode) { " — café 日本 🚀 e\u0301\n\"quoted\" \\u2014" }

  before do
    MatrixHelper.configure_for_fake!
    MatrixHelper.register_legion_tool!
  end

  after do
    MatrixHelper.unregister_legion_tool!
    MatrixHelper.restore_started_state!
  end

  # Net::HTTP can expose SSE as ASCII-8BIT, even with a UTF-8 charset header.
  # Reproduce the client's second JSON serialization without changing its bytes
  # or encoding label. Before the fix this raises JSON::GeneratorError for E2.
  def recorded_events
    expect(last_response.status).to eq(200)
    body = last_response.body
    wire = "HTTP/1.1 200 OK\r\nContent-Type: text/event-stream; charset=utf-8\r\nContent-Length: #{body.bytesize}\r\n\r\n".b + body.b
    io = Net::BufferedIO.new(StringIO.new(wire))
    response = Net::HTTPResponse.read_new(io)
    raw = response.reading_body(io, true) { response.body }
    recorded = Legion::JSON.pretty_generate({ raw_sse: raw })
    MatrixHelper.parse_sse(Legion::JSON.load(recorded).fetch(:raw_sse))
  end

  def request_stream(scenario:)
    FakeProvider.with_scenario(scenario) do
      post '/v1/responses',
           Legion::JSON.dump({ model: MatrixHelper::FAKE_MODEL, input: 'Echo the supplied value.', stream: true, max_output_tokens: 1024 }),
           'CONTENT_TYPE' => 'application/json'
    end
  end

  def event_payloads(events:, type:, **)
    events.filter_map { |event| event.last if event.first == type }
  end

  %i[buffered unbuffered].each do |buffering|
    %i[ascii unicode_followup unicode_exchange].each do |scenario|
      it "preserves the full MCP exchange and follow-up with #{scenario}, #{buffering}" do
        Legion::Settings[:llm][:streaming][:tool_call_buffering] = buffering
        value = scenario == :unicode_exchange ? unicode : 'ping'
        # The failing live provider frame carried exactly this text delta:
        # {"index":0,"delta":{"content":" —"},"logprobs":null,"finish_reason":null,"token_ids":null}
        text = scenario == :ascii ? 'Inventory checked.' : ' —'
        allow(FakeProvider::Fixtures).to receive(:server_tool_legion_response).and_wrap_original do |original, model|
          response = original.call(model)
          if response.tool_calls.empty?
            response.with(text: text)
          else
            # Provider fragments have unresolved ownership. The real executor
            # classifies this registered tool and executes it through MCP.
            response.with(tool_calls: response.tool_calls.map { |call| call.with(arguments: { value: value }, source: nil) })
          end
        end
        expect(MatrixHelper::FakeLegionEcho).to receive(:call).with(value: value).once.and_call_original

        request_stream(scenario: :server_tool_legion)
        events = recorded_events
        expect(events.last.first).to eq('response.completed')
        completed = events.last.last.fetch(:response)
        expect(completed[:status]).to eq('completed')
        expect(completed[:output].map { |item| item[:type] }).to eq(%w[mcp_call message])
        item = completed[:output].first
        expect(item).to include(name: 'fake_legion_echo', server_label: 'legion', status: 'completed', output: "echo:#{value}", error: nil)
        expect(Legion::JSON.load(item[:arguments])).to eq(value: value)
        expect(completed[:output].last.dig(:content, 0, :text)).to eq(text)
        expect(events.count { |name, _| name == 'response.mcp_call.completed' }).to eq(1)
        expect(event_payloads(events: events, type: 'response.output_text.delta').map { |data| data[:delta] }.join).to eq(text)
        expect(event_payloads(events: events, type: 'response.output_item.done').map { |data| data[:item] }).to include(item)
        expect(events.map { |_, data| data[:sequence_number] }).to eq((1..events.length).to_a)

        # The provider still receives the original tool result, not wire escapes.
        followup = FakeProvider.calls.last.fetch(:messages)
        tool_result = followup.find { |message| message.role == :tool }
        expect(tool_result.content).to eq("echo:#{value}")
      end
    end
  end

  it 'preserves Unicode text even without an MCP call' do
    allow(FakeProvider::Fixtures).to receive(:stream_text).and_wrap_original do |original, model, **options, &consumer|
      original.call(model, **options, prefix: unicode, &consumer)
    end

    request_stream(scenario: :stream_text)
    events = recorded_events
    text = event_payloads(events: events, type: 'response.output_text.delta').map { |data| data[:delta] }.join
    expect(text).to eq("#{unicode}Hello there.")
    expect(events.last.last.dig(:response, :output, 0, :content, 0, :text)).to eq(text)
  end
end
