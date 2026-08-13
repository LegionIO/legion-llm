# frozen_string_literal: true

# SSOT v3 §19 / Task 11 — streaming preflight.
#
# Proves a routing rejection encountered while selecting a streaming lane
# surfaces as a mapped HTTP error BEFORE the SSE event-stream opens — never an
# SSE server_error emitted after the response headers are already committed.
#
# The offering here supports :chat but conclusively NOT :stream_chat, so a
# streaming request cannot route. next_lane rejects; the executor's
# stream_preflight! raises Errors::RoutingRejected before content_type is set to
# text/event-stream; the route's RoutingErrorMapper rescue renders an ordinary
# JSON HTTP error.
require_relative 'matrix_helper'

RSpec.describe '[matrix] streaming preflight rejection', type: :request do
  include Rack::Test::Methods

  let(:app) { MatrixHelper.app_class }

  before do
    MatrixHelper.configure_for_fake!
    # Re-publish FakeProvider so streaming is conclusively unsupported.
    Legion::Extensions::Llm::Inventory::Registry.reset!
    SsotV3SnapshotFactory.activate(
      provider_family: 'fake',
      instance_id:     'test',
      drafts:          [
        SsotV3SnapshotFactory.offering_draft(
          model:        MatrixHelper::FAKE_MODEL,
          tier:         :local,
          supported:    %i[chat],
          unsupported:  %i[stream_chat],
          capabilities: { streaming: :unsupported },
          context:      200_000
        )
      ],
      callable:        FakeProvider.adapter
    )
  end

  after do
    MatrixHelper.restore_started_state!
  end

  it 'returns a mapped HTTP error (not an opened SSE) when the streaming lane is rejected at preflight' do
    post '/v1/chat/completions',
         Legion::JSON.dump(model:    MatrixHelper::FAKE_MODEL,
                           stream:   true,
                           messages: [{ role: 'user', content: 'stream please' }]),
         { 'CONTENT_TYPE' => 'application/json' }

    resp = last_response

    # A routing rejection → HTTP status via RoutingErrorMapper (openai dialect
    # maps the rejection kind to 403/424/503), NOT a 200 SSE stream. The exact
    # kind is the router's business; the invariant here is "HTTP error, no SSE".
    expect(resp.status).not_to eq(200)
    expect([403, 424, 425, 503]).to include(resp.status)

    # Proof the SSE never opened: the response is a JSON error body, not an
    # event-stream, and carries no SSE data frames.
    expect(resp.headers['Content-Type'].to_s).to include('application/json')
    expect(resp.headers['Content-Type'].to_s).not_to include('text/event-stream')
    expect(resp.body).not_to include('data:')

    body = Legion::JSON.load(resp.body)
    expect(body[:error]).to be_a(Hash)
    expect(body[:error][:type].to_s).not_to be_empty
  end

  it 'still streams successfully (200 SSE) once stream_chat is a supported operation' do
    # Re-publish with full streaming evidence — the happy path opens SSE.
    Legion::Extensions::Llm::Inventory::Registry.reset!
    SsotV3SnapshotFactory.activate(
      provider_family: 'fake',
      instance_id:     'test',
      drafts:          [
        SsotV3SnapshotFactory.offering_draft(
          model:        MatrixHelper::FAKE_MODEL,
          tier:         :local,
          supported:    %i[chat stream_chat],
          capabilities: { streaming: :supported },
          context:      200_000
        )
      ],
      callable:        FakeProvider.adapter
    )

    FakeProvider.with_scenario(:stream_text) do
      post '/v1/chat/completions',
           Legion::JSON.dump(model:    MatrixHelper::FAKE_MODEL,
                             stream:   true,
                             messages: [{ role: 'user', content: 'stream please' }]),
           { 'CONTENT_TYPE' => 'application/json' }
    end

    resp = last_response
    expect(resp.status).to eq(200)
    expect(resp.headers['Content-Type'].to_s).to include('text/event-stream')
    expect(resp.body).to include('data:')
  end
end
