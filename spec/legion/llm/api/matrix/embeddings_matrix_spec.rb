# frozen_string_literal: true

# Permanent guard for the SSOT v3 embed contract (matrix had NO embed scenario).
#
# The harness FakeProvider callable returns the 0.8.0 documented embed
# artifact Hash — the production shape every lex-llm-* parse_embedding_response
# produces, mirroring how the chat path returns the canonical Response. POST
# /v1/embeddings must normalize it at the embed consumer boundary
# (Call::Embeddings.provider_vectors) and answer with
# OpenAI-shaped vectors.
#
# Scenarios (each was a live e2e red, 2026-08-17):
#   1. native callable -> 200 OpenAI-shaped vector (pre-fix: 502)
#   2. array input N=3 -> N entries, sequential index, input order (pre-fix:
#      collapsed to element 0)
#   3. encoding_format: base64 -> base64 string of little-endian float32
#      (pre-fix: key ignored, raw floats emitted)
#   4. missing input -> 400 with the COMPLETE error envelope (message, type,
#      param, code all present; pre-fix: param/code keys absent)
# Plus: routing attribution headers (x-legion-provider/instance/model) on
# success (pre-fix: never emitted on this route) and usage from the provider
# token count, not the input word count.
# This file must stay green as a commit gate.

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

  # FakeProvider.embed_response formula (spec/support/fake_provider.rb):
  # 8 dims, ((text.bytes.sum + i) % 7) / 7.0 — deterministic per input text.
  def fake_vector_for(text)
    Array.new(8) { |i| ((text.to_s.bytes.sum + i) % 7) / 7.0 }
  end

  # FakeProvider.embed_response token formula: text.length / 4 + 1.
  def fake_tokens_for(text)
    (text.to_s.length / 4) + 1
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

    # D6: usage is the provider's token count (FakeProvider: length/4 + 1),
    # NOT the input word count.
    expect(body.dig(:usage, :prompt_tokens)).to eq(fake_tokens_for(input))
    expect(body.dig(:usage, :total_tokens)).to eq(fake_tokens_for(input))

    # D5: routing attribution headers on the embeddings success path.
    expect(last_response.headers['X-Legion-Provider']).to eq('fake')
    expect(last_response.headers['X-Legion-Instance']).to eq('test')
    expect(last_response.headers['X-Legion-Model']).to eq('fake-default')
  end

  it 'answers one entry per array element, sequential index, input order preserved' do
    inputs = %w[apple banana cherry]
    post '/v1/embeddings',
         Legion::JSON.dump({ input: inputs, model: 'fake-default' }),
         'CONTENT_TYPE' => 'application/json'

    expect(last_response.status).to eq(200), "Expected 200, got #{last_response.status}: #{last_response.body}"

    body = Legion::JSON.load(last_response.body)
    expect(body[:object]).to eq('list')
    expect(body[:model]).to eq('fake-default')

    data = body[:data]
    expect(data).to be_an(Array)
    expect(data.size).to eq(inputs.size), "expected #{inputs.size} entries, got #{data.size}"

    data.each_with_index do |entry, index|
      expect(entry[:object]).to eq('embedding')
      expect(entry[:index]).to eq(index)
      # Each text maps to its own deterministic vector — this pins ORDER
      # (a collapsed/reordered batch would mismatch on at least one entry).
      expect(entry[:embedding]).to eq(fake_vector_for(inputs[index]))
    end

    # Batch entries share ONE provider dispatch, so no per-entry provider
    # token count is attributed (build_batch_entry carries no :tokens — a
    # single dispatch's input_tokens cannot be honestly split per item).
    # Usage falls back to the summed input word count (translator contract,
    # pinned in openai_response_spec 'falls back to summed word count').
    expect(body.dig(:usage, :prompt_tokens)).to eq(inputs.sum { |t| t.split.size })
    expect(body.dig(:usage, :total_tokens)).to eq(body.dig(:usage, :prompt_tokens))

    expect(last_response.headers['X-Legion-Provider']).to eq('fake')
    expect(last_response.headers['X-Legion-Instance']).to eq('test')
    expect(last_response.headers['X-Legion-Model']).to eq('fake-default')
  end

  it 'answers a base64 string of little-endian float32 when encoding_format is base64' do
    input = 'base64 encoding format matrix probe'
    post '/v1/embeddings',
         Legion::JSON.dump({ input: input, model: 'fake-default' }),
         'CONTENT_TYPE' => 'application/json'
    float_body = Legion::JSON.load(last_response.body)
    expect(last_response.status).to eq(200), "Expected 200, got #{last_response.status}: #{last_response.body}"

    post '/v1/embeddings',
         Legion::JSON.dump({ input: input, model: 'fake-default', encoding_format: 'base64' }),
         'CONTENT_TYPE' => 'application/json'
    expect(last_response.status).to eq(200), "Expected 200, got #{last_response.status}: #{last_response.body}"

    body = Legion::JSON.load(last_response.body)
    expect(body[:object]).to eq('list')

    entry = body[:data].first
    expect(entry[:object]).to eq('embedding')
    expect(entry[:index]).to eq(0)

    encoded = entry[:embedding]
    expect(encoded).to be_a(String), "encoding_format=base64 must yield a String, got #{encoded.class}"

    # Decode (raises on invalid base64) and compare BYTE-exact with the
    # float form's vector packed as little-endian float32.
    raw = encoded.unpack1('m0')
    float_vector = float_body[:data].first[:embedding]
    expect(raw).to eq(float_vector.pack('g*'))

    # Default form stays raw floats (unchanged behavior).
    expect(float_vector).to eq(fake_vector_for(input))

    expect(body.dig(:usage, :prompt_tokens)).to eq(fake_tokens_for(input))
    expect(last_response.headers['X-Legion-Provider']).to eq('fake')
  end

  it 'rejects a missing input with 400 and the complete error envelope' do
    post '/v1/embeddings',
         Legion::JSON.dump({ model: 'fake-default' }),
         'CONTENT_TYPE' => 'application/json'

    expect(last_response.status).to eq(400)

    body = Legion::JSON.load(last_response.body)
    error = body[:error]
    expect(error).to be_a(Hash)
    expect(error[:message]).to eq('input is required')
    expect(error[:type]).to eq('invalid_request_error')
    # OpenAI error objects ALWAYS carry param and code (null when N/A).
    expect(error.key?(:param)).to be(true)
    expect(error.key?(:code)).to be(true)
    expect(error[:param]).to eq('input')
    expect(error[:code]).to be_nil
  end
end
