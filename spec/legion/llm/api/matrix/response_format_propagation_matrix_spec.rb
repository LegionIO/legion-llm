# frozen_string_literal: true

# Regression spec: a client's response_format must reach the provider.
#
# Root cause: native_dispatch_options (tool_injection.rb) read
# Request#response_format nowhere, so it was used for lane selection only
# (Router#structured_output_required?) and no schema reached the wire.
# Every structured-output caller (Legion::LLM.structured, GaiaCaller, client
# response_format) got free text back, and StructuredOutput logged JSON parse
# failures. The dispatch now forwards it as params.response_format in the
# OpenAI wire shape, which the vLLM and OpenAI-compatible translators read.
#
# It MUST fail before the fix and pass after.

require_relative 'matrix_helper'

RSpec.describe '[matrix] response_format propagation', type: :request do
  include Rack::Test::Methods

  let(:app) { MatrixHelper.app_class }

  let(:schema) do
    { type:       'object',
      properties: { decision: { type: 'string', enum: %w[allow deny ask] } },
      required:   %w[decision] }
  end

  before { MatrixHelper.configure_for_fake! }
  after { MatrixHelper.restore_started_state! }

  def post_chat(response_format)
    body = { model: 'fake-default', messages: [{ role: 'user', content: 'judge this' }] }
    body[:response_format] = response_format if response_format
    FakeProvider.with_scenario(:text) do
      post '/v1/chat/completions', Legion::JSON.dump(body), 'CONTENT_TYPE' => 'application/json'
    end
    expect(last_response.status).to eq(200), "Expected 200, got #{last_response.status}: #{last_response.body}"
    call = FakeProvider.calls.last
    expect(call).not_to be_nil, 'FakeProvider received no calls'
    call
  end

  def deep_symbolize(value)
    case value
    when Hash then value.to_h { |k, v| [k.to_sym, deep_symbolize(v)] }
    when Array then value.map { |v| deep_symbolize(v) }
    else value
    end
  end

  it 'forwards an OpenAI-shaped json_schema response_format to the provider' do
    call = post_chat({ type: 'json_schema', json_schema: { name: 'verdict', strict: true, schema: schema } })
    expect(deep_symbolize(call[:params] || {})[:response_format]).to eq(
      { type: 'json_schema', json_schema: { name: 'verdict', schema: deep_symbolize(schema), strict: true } }
    ), "provider params were #{call[:params].inspect} — native_dispatch_options dropped response_format"
  end

  it 'normalizes the internal {type: json_schema, schema:} shape to the OpenAI wire shape' do
    call = post_chat({ type: 'json_schema', schema: schema })
    expect(deep_symbolize(call[:params] || {})[:response_format]).to eq(
      { type: 'json_schema', json_schema: { name: 'response', schema: deep_symbolize(schema) } }
    )
  end

  it 'forwards json_object mode' do
    call = post_chat({ type: 'json_object' })
    expect(deep_symbolize(call[:params] || {})[:response_format]).to eq({ type: 'json_object' })
  end

  it 'sends no response_format when the client omits it' do
    call = post_chat(nil)
    expect(deep_symbolize(call[:params] || {})[:response_format]).to be_nil
  end
end
