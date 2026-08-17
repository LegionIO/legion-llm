# frozen_string_literal: true

# Permanent guard for the SSOT v3 embed contract (matrix had NO embed scenario).
#
# The harness FakeProvider callable returns the provider-native
# Legion::Extensions::Llm::Embedding value object — the production shape every
# lex-llm-* parse_embedding_response produces, mirroring how the chat path
# returns the canonical Message. POST /v1/embeddings must normalize it at the
# embed consumer boundary (Call::Embeddings.provider_vectors) and answer with
# OpenAI-shaped vectors.
#
# Pre-fix, provider_vectors understood only the legacy {result:, usage:} Hash
# or a raw numeric array: the Embedding object collapsed to a dropped vector,
# Call::Embeddings raised ProviderError 'embedding provider returned no usable
# vector', and the route answered 502 — every live embed failed.
# This scenario fails with 502 pre-fix and must stay green as a commit gate.

require_relative 'matrix_helper'

RSpec.describe '[matrix] POST /v1/embeddings x SSOT v3 native Embedding callable', type: :request do
  include Rack::Test::Methods

  let(:app) { MatrixHelper.app_class }

  before do
    MatrixHelper.configure_for_fake!
  end

  after do
    MatrixHelper.restore_started_state!
  end

  it 'answers 200 with the OpenAI-shaped embedding vector from the native callable' do
    input = 'hello world from the matrix'
    post '/v1/embeddings',
         Legion::JSON.dump({ input: input, model: 'fake-default' }),
         'CONTENT_TYPE' => 'application/json'

    expect(last_response.status).to eq(200), "Expected 200, got #{last_response.status}: #{last_response.body}"

    body = Legion::JSON.load(last_response.body)
    expect(body[:object]).to eq('list')
    expect(body[:model]).to eq('fake-default')

    data = body[:data]
    expect(data).to be_an(Array)
    expect(data.size).to eq(1)
    expect(data.first[:object]).to eq('embedding')
    expect(data.first[:index]).to eq(0)

    embedding = data.first[:embedding]
    expect(embedding).to be_an(Array)
    expect(embedding.size).to eq(8)
    expect(embedding).to all(be_a(Float))

    # The route passes the result hash as usage; embedding_token_count finds no
    # token key there and falls back to the input word count (pre-existing
    # route behavior, asserted to pin the shape).
    expect(body.dig(:usage, :prompt_tokens)).to eq(input.split.size)
    expect(body.dig(:usage, :total_tokens)).to eq(input.split.size)
  end
end
