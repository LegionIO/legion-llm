# frozen_string_literal: true

require 'spec_helper'
require 'legion/llm/api/routing_error_mapper'

RSpec.describe Legion::LLM::API::RoutingErrorMapper do
  subject(:mapper) { described_class }

  let(:routing_ns) { Legion::Extensions::Llm::Routing }
  let(:base_reason) { 'test routing failure' }

  # Construct a real Phase 1 Rejection for the given kind.
  def rejection(kind:, reason: base_reason)
    routing_ns::Rejection.new(
      kind:                 kind,
      reason:               reason,
      inventory_generation: 1,
      candidate_counts:     {}
    )
  end

  # ── Response value object ────────────────────────────────────────────────

  describe 'Response value object' do
    subject(:response) do
      mapper.call(rejection: rejection(kind: :invalid_request), dialect: :native)
    end

    it 'is a Data instance' do
      expect(described_class::Response.ancestors).to include(Data)
    end

    it 'exposes status, headers, and body readers' do
      expect(response).to respond_to(:status, :headers, :body)
    end

    it 'is frozen' do
      expect(response).to be_frozen
    end

    it 'headers hash is frozen' do
      expect(response.headers).to be_frozen
    end

    it 'body hash is frozen' do
      expect(response.body).to be_frozen
    end

    it 'status is an Integer' do
      expect(response.status).to be_a(Integer)
    end
  end

  # ── ArgumentError for invalid dialect ────────────────────────────────────

  describe 'invalid dialect guard' do
    it 'raises ArgumentError for an unrecognised dialect symbol' do
      expect do
        mapper.call(rejection: rejection(kind: :invalid_request), dialect: :graphql)
      end.to raise_error(ArgumentError, /graphql/)
    end

    it 'raises ArgumentError for nil' do
      expect do
        mapper.call(rejection: rejection(kind: :invalid_request), dialect: nil)
      end.to raise_error(ArgumentError)
    end

    it 'raises ArgumentError for a string instead of symbol' do
      expect do
        mapper.call(rejection: rejection(kind: :invalid_request), dialect: 'native')
      end.to raise_error(ArgumentError)
    end
  end

  # ── §18 status matrix (all 8 §18 kinds × 3 dialects) ────────────────────

  describe '§18 status mapping matrix' do
    expected = {
      invalid_routing_context: { native: 500, openai: 500, anthropic: 500 },
      invalid_request:         { native: 400, openai: 400, anthropic: 400 },
      policy_denied:           { native: 403, openai: 403, anthropic: 403 },
      failed_dependency:       { native: 424, openai: 424, anthropic: 424 },
      too_early:               { native: 425, openai: 503, anthropic: 529 },
      service_unavailable:     { native: 503, openai: 503, anthropic: 529 },
      context_rejected:        { native: 400, openai: 400, anthropic: 400 },
      attempts_exhausted:      { native: 503, openai: 503, anthropic: 529 }
    }

    expected.each do |kind, by_dialect|
      context "kind=#{kind}" do
        by_dialect.each do |dialect, expected_status|
          it "#{dialect} → HTTP #{expected_status}" do
            r = mapper.call(rejection: rejection(kind: kind), dialect: dialect)
            expect(r.status).to eq(expected_status)
          end
        end
      end
    end
  end

  # ── too_early dialect distinction (native 425, compat retryable) ─────────

  describe 'too_early dialect distinction (D16)' do
    it 'native stays 425 so Legion-aware clients distinguish incomplete authority' do
      r = mapper.call(rejection: rejection(kind: :too_early), dialect: :native)
      expect(r.status).to eq(425)
    end

    it 'openai → 503 (retryable for SDK auto-retry)' do
      r = mapper.call(rejection: rejection(kind: :too_early), dialect: :openai)
      expect(r.status).to eq(503)
    end

    it 'anthropic → 529 (retryable for SDK auto-retry)' do
      r = mapper.call(rejection: rejection(kind: :too_early), dialect: :anthropic)
      expect(r.status).to eq(529)
    end
  end

  # ── Retry-After header presence / absence ────────────────────────────────

  describe 'Retry-After header' do
    retry_after_kinds = %i[too_early service_unavailable attempts_exhausted]
    no_retry_kinds    = %i[invalid_request policy_denied context_rejected
                           invalid_routing_context failed_dependency]

    %i[native openai anthropic].each do |dialect|
      context "dialect=#{dialect}" do
        retry_after_kinds.each do |kind|
          it "is present for kind=#{kind}" do
            r = mapper.call(rejection: rejection(kind: kind), dialect: dialect)
            expect(r.headers).to have_key('Retry-After'),
                                 "expected Retry-After for #{kind}/#{dialect}"
          end
        end

        no_retry_kinds.each do |kind|
          it "is absent for kind=#{kind}" do
            r = mapper.call(rejection: rejection(kind: kind), dialect: dialect)
            expect(r.headers).not_to have_key('Retry-After'),
                                     "unexpected Retry-After for #{kind}/#{dialect}"
          end
        end
      end
    end

    it 'Retry-After value is a string representation of a positive integer' do
      r = mapper.call(rejection: rejection(kind: :too_early), dialect: :native)
      val = r.headers['Retry-After']
      expect(val).to match(/\A[1-9]\d*\z/)
    end
  end

  # ── Native body shape ─────────────────────────────────────────────────────

  describe 'native body shape { error: { code:, message: } }' do
    it 'has the correct envelope keys' do
      r = mapper.call(rejection: rejection(kind: :invalid_request, reason: 'bad input'), dialect: :native)
      expect(r.body).to match(error: { code: String, message: 'bad input' })
    end

    it 'too_early code is routing_too_early (D16)' do
      r = mapper.call(rejection: rejection(kind: :too_early), dialect: :native)
      expect(r.body[:error][:code]).to eq('routing_too_early')
    end

    it 'invalid_routing_context code is internal_error' do
      r = mapper.call(rejection: rejection(kind: :invalid_routing_context), dialect: :native)
      expect(r.body[:error][:code]).to eq('internal_error')
    end

    it 'policy_denied code is policy_denied' do
      r = mapper.call(rejection: rejection(kind: :policy_denied), dialect: :native)
      expect(r.body[:error][:code]).to eq('policy_denied')
    end

    it 'failed_dependency code is failed_dependency' do
      r = mapper.call(rejection: rejection(kind: :failed_dependency), dialect: :native)
      expect(r.body[:error][:code]).to eq('failed_dependency')
    end

    it 'service_unavailable code is service_unavailable' do
      r = mapper.call(rejection: rejection(kind: :service_unavailable), dialect: :native)
      expect(r.body[:error][:code]).to eq('service_unavailable')
    end

    it 'context_rejected code is context_rejected' do
      r = mapper.call(rejection: rejection(kind: :context_rejected), dialect: :native)
      expect(r.body[:error][:code]).to eq('context_rejected')
    end

    it 'attempts_exhausted code is attempts_exhausted' do
      r = mapper.call(rejection: rejection(kind: :attempts_exhausted), dialect: :native)
      expect(r.body[:error][:code]).to eq('attempts_exhausted')
    end

    it 'preserves the rejection reason as message' do
      r = mapper.call(rejection: rejection(kind: :policy_denied, reason: 'model blacklisted'), dialect: :native)
      expect(r.body[:error][:message]).to eq('model blacklisted')
    end
  end

  # ── OpenAI body shape ─────────────────────────────────────────────────────

  describe 'openai body shape { error: { message:, type:, code: } }' do
    it 'has the correct envelope keys' do
      r = mapper.call(rejection: rejection(kind: :invalid_request, reason: 'bad'), dialect: :openai)
      expect(r.body).to match(error: hash_including(message: 'bad', type: String))
      expect(r.body[:error]).to have_key(:code)
    end

    it 'invalid_routing_context → type server_error, status 500' do
      r = mapper.call(rejection: rejection(kind: :invalid_routing_context), dialect: :openai)
      expect(r.status).to eq(500)
      expect(r.body[:error][:type]).to eq('server_error')
    end

    it 'invalid_request → type invalid_request_error, status 400' do
      r = mapper.call(rejection: rejection(kind: :invalid_request), dialect: :openai)
      expect(r.status).to eq(400)
      expect(r.body[:error][:type]).to eq('invalid_request_error')
    end

    it 'policy_denied → type permission_error, status 403' do
      r = mapper.call(rejection: rejection(kind: :policy_denied), dialect: :openai)
      expect(r.status).to eq(403)
      expect(r.body[:error][:type]).to eq('permission_error')
    end

    it 'failed_dependency → type server_error, status 424' do
      r = mapper.call(rejection: rejection(kind: :failed_dependency), dialect: :openai)
      expect(r.status).to eq(424)
      expect(r.body[:error][:type]).to eq('server_error')
    end

    it 'too_early → type server_error, code routing_too_early, status 503 (D16)' do
      r = mapper.call(rejection: rejection(kind: :too_early), dialect: :openai)
      expect(r.status).to eq(503)
      expect(r.body[:error][:type]).to eq('server_error')
      expect(r.body[:error][:code]).to eq('routing_too_early')
    end

    it 'service_unavailable → type server_error, status 503' do
      r = mapper.call(rejection: rejection(kind: :service_unavailable), dialect: :openai)
      expect(r.status).to eq(503)
      expect(r.body[:error][:type]).to eq('server_error')
    end

    it 'context_rejected → type invalid_request_error, status 400' do
      r = mapper.call(rejection: rejection(kind: :context_rejected), dialect: :openai)
      expect(r.status).to eq(400)
      expect(r.body[:error][:type]).to eq('invalid_request_error')
    end

    it 'attempts_exhausted → type server_error, status 503' do
      r = mapper.call(rejection: rejection(kind: :attempts_exhausted), dialect: :openai)
      expect(r.status).to eq(503)
      expect(r.body[:error][:type]).to eq('server_error')
    end

    it 'preserves the rejection reason as message' do
      r = mapper.call(rejection: rejection(kind: :service_unavailable, reason: 'all down'), dialect: :openai)
      expect(r.body[:error][:message]).to eq('all down')
    end
  end

  # ── Anthropic body shape ──────────────────────────────────────────────────

  describe 'anthropic body shape { type: "error", error: { type:, message: } }' do
    it 'has the outer type: "error" key' do
      r = mapper.call(rejection: rejection(kind: :invalid_request, reason: 'bad'), dialect: :anthropic)
      expect(r.body[:type]).to eq('error')
    end

    it 'has the correct nested error envelope' do
      r = mapper.call(rejection: rejection(kind: :invalid_request, reason: 'bad'), dialect: :anthropic)
      expect(r.body).to match(type: 'error', error: { type: String, message: 'bad' })
    end

    it 'invalid_routing_context → error.type api_error, status 500' do
      r = mapper.call(rejection: rejection(kind: :invalid_routing_context), dialect: :anthropic)
      expect(r.status).to eq(500)
      expect(r.body[:error][:type]).to eq('api_error')
    end

    it 'invalid_request → error.type invalid_request_error, status 400' do
      r = mapper.call(rejection: rejection(kind: :invalid_request), dialect: :anthropic)
      expect(r.status).to eq(400)
      expect(r.body[:error][:type]).to eq('invalid_request_error')
    end

    it 'policy_denied → error.type permission_error, status 403' do
      r = mapper.call(rejection: rejection(kind: :policy_denied), dialect: :anthropic)
      expect(r.status).to eq(403)
      expect(r.body[:error][:type]).to eq('permission_error')
    end

    it 'failed_dependency → error.type api_error, status 424' do
      r = mapper.call(rejection: rejection(kind: :failed_dependency), dialect: :anthropic)
      expect(r.status).to eq(424)
      expect(r.body[:error][:type]).to eq('api_error')
    end

    it 'too_early → error.type overloaded_error, status 529 (D16)' do
      r = mapper.call(rejection: rejection(kind: :too_early), dialect: :anthropic)
      expect(r.status).to eq(529)
      expect(r.body[:error][:type]).to eq('overloaded_error')
    end

    it 'service_unavailable → error.type overloaded_error, status 529' do
      r = mapper.call(rejection: rejection(kind: :service_unavailable), dialect: :anthropic)
      expect(r.status).to eq(529)
      expect(r.body[:error][:type]).to eq('overloaded_error')
    end

    it 'context_rejected → error.type invalid_request_error, status 400' do
      r = mapper.call(rejection: rejection(kind: :context_rejected), dialect: :anthropic)
      expect(r.status).to eq(400)
      expect(r.body[:error][:type]).to eq('invalid_request_error')
    end

    it 'attempts_exhausted → error.type overloaded_error, status 529' do
      r = mapper.call(rejection: rejection(kind: :attempts_exhausted), dialect: :anthropic)
      expect(r.status).to eq(529)
      expect(r.body[:error][:type]).to eq('overloaded_error')
    end

    it 'preserves the rejection reason as message' do
      r = mapper.call(
        rejection: rejection(kind: :too_early, reason: 'no ready authority — routing_too_early'),
        dialect:   :anthropic
      )
      expect(r.body[:error][:message]).to eq('no ready authority — routing_too_early')
    end
  end
end
