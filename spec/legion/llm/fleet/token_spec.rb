# frozen_string_literal: true

require 'spec_helper'

RSpec.describe Legion::LLM::Fleet::TokenIssuer do
  let(:payload) do
    {
      request_id:        'req-1',
      correlation_id:    'corr-1',
      idempotency_key:   'idem-1',
      operation:         :chat,
      provider:          'ollama',
      provider_instance: 'default',
      model:             'llama3.2',
      reply_to:          'llm.fleet.reply.test',
      message_context:   { conversation_id: 'conv-1' },
      params:            { messages: [{ role: 'user', content: 'hello' }] },
      caller:            { source: 'test' },
      trace_context:     { trace_id: 'trace-1' },
      timeout_seconds:   30,
      expires_at:        (Time.now.utc + 30).iso8601
    }
  end

  before do
    jwt = Module.new do
      class << self
        attr_accessor :issued_payload

        def issue(payload, signing_key:, ttl:, issuer:, algorithm: 'HS256')
          self.issued_payload = {
            payload:     payload,
            signing_key: signing_key,
            ttl:         ttl,
            issuer:      issuer,
            algorithm:   algorithm
          }
          'jwt-token'
        end
      end
    end
    crypt = Module.new do
      define_singleton_method(:cluster_secret) { 'secret' }
    end
    crypt.const_set(:JWT, jwt)
    stub_const('Legion::Crypt', crypt)
  end

  it 'issues signed fleet JWTs with required routing and identity claims' do
    token = described_class.issue(payload)

    expect(token).to eq('jwt-token')
    claims = Legion::Crypt::JWT.issued_payload[:payload]
    expect(claims).to include(
      iss:               'legion-llm',
      aud:               'lex-llm-fleet-worker',
      exp:               a_kind_of(Integer),
      nbf:               a_kind_of(Integer),
      jti:               a_string_matching(/\Afleet-jti-/),
      request_id:        'req-1',
      correlation_id:    'corr-1',
      idempotency_key:   'idem-1',
      operation:         :chat,
      provider:          'ollama',
      provider_instance: 'default',
      model:             'llama3.2',
      reply_to:          'llm.fleet.reply.test',
      message_context:   { conversation_id: 'conv-1' },
      params:            { messages: [{ role: 'user', content: 'hello' }] },
      caller:            { source: 'test' },
      trace_context:     { trace_id: 'trace-1' },
      timeout_seconds:   30,
      expires_at:        payload[:expires_at]
    )
  end

  it 'fails closed when no signing key is available' do
    allow(Legion::Crypt).to receive(:cluster_secret).and_raise(RuntimeError, 'missing key')

    expect { described_class.issue(payload) }.to raise_error(Legion::LLM::Fleet::TokenError, /signing key/)
  end
end

RSpec.describe Legion::LLM::Fleet::TokenValidator do
  let(:envelope) do
    {
      request_id:        'req-1',
      correlation_id:    'corr-1',
      idempotency_key:   'idem-1',
      operation:         :chat,
      provider:          'ollama',
      provider_instance: 'default',
      model:             'llama3.2',
      reply_to:          'llm.fleet.reply.test',
      message_context:   { conversation_id: 'conv-1' },
      params:            { messages: [{ role: 'user', content: 'hello' }] },
      caller:            { source: 'test' },
      trace_context:     { trace_id: 'trace-1' },
      timeout_seconds:   30,
      expires_at:        (Time.now.utc + 30).iso8601
    }
  end

  let(:claims) do
    now = Time.now.to_i
    {
      iss:               'legion-llm',
      aud:               'lex-llm-fleet-worker',
      exp:               now + 30,
      nbf:               now - 1,
      jti:               'jti-1',
      request_id:        'req-1',
      correlation_id:    'corr-1',
      idempotency_key:   'idem-1',
      operation:         :chat,
      provider:          'ollama',
      provider_instance: 'default',
      model:             'llama3.2',
      reply_to:          'llm.fleet.reply.test',
      message_context:   { conversation_id: 'conv-1' },
      params:            { messages: [{ role: 'user', content: 'hello' }] },
      caller:            { source: 'test' },
      trace_context:     { trace_id: 'trace-1' },
      timeout_seconds:   30,
      expires_at:        envelope[:expires_at]
    }
  end

  before do
    described_class.reset_replay_cache!
    jwt = Module.new do
      class << self
        attr_accessor :claims, :last_verify_options

        def verify(_token, verification_key:, issuer:, **opts)
          raise 'missing verification key' if verification_key.nil?

          self.last_verify_options = { issuer: issuer }.merge(opts)
          raise 'unexpected issuer verification' if opts[:verify_issuer] != true

          claims
        end
      end
    end
    jwt.claims = claims
    crypt = Module.new do
      define_singleton_method(:cluster_secret) { 'secret' }
    end
    crypt.const_set(:JWT, jwt)
    stub_const('Legion::Crypt', crypt)
  end

  it 'validates a signed token and returns claims' do
    expect(described_class.validate!(token: 'jwt-token', envelope: envelope)).to include(jti: 'jti-1')
  end

  it 'requires Legion::Crypt JWT verification' do
    hide_const('Legion::Crypt')

    expect do
      described_class.validate!(token: 'jwt-token', envelope: envelope)
    end.to raise_error(Legion::LLM::Fleet::TokenError, /Legion::Crypt/)
  end

  it 'rejects replayed jtis' do
    described_class.validate!(token: 'jwt-token', envelope: envelope)

    expect do
      described_class.validate!(token: 'jwt-token', envelope: envelope)
    end.to raise_error(Legion::LLM::Fleet::TokenError, /replay/)
  end

  it 'rejects mismatched envelope claims' do
    Legion::Crypt::JWT.claims = claims.merge(model: 'other')

    expect do
      described_class.validate!(token: 'jwt-token', envelope: envelope)
    end.to raise_error(Legion::LLM::Fleet::TokenError, /model/)
  end

  it 'rejects expired tokens' do
    Legion::Crypt::JWT.claims = claims.merge(exp: Time.now.to_i - 60)

    expect do
      described_class.validate!(token: 'jwt-token', envelope: envelope)
    end.to raise_error(Legion::LLM::Fleet::TokenError, /expired/)
  end

  it 'rejects expired request envelopes even when token exp is still valid' do
    Legion::Crypt::JWT.claims = claims.merge(expires_at: (Time.now.utc - 60).iso8601)

    expect do
      described_class.validate!(token: 'jwt-token', envelope: envelope.merge(expires_at: (Time.now.utc - 60).iso8601))
    end.to raise_error(Legion::LLM::Fleet::TokenError, /request expired/)
  end

  it 'rejects not-yet-valid tokens' do
    Legion::Crypt::JWT.claims = claims.merge(nbf: Time.now.to_i + 60)

    expect do
      described_class.validate!(token: 'jwt-token', envelope: envelope)
    end.to raise_error(Legion::LLM::Fleet::TokenError, /not yet valid/)
  end

  it 'uses fleet auth settings for issuer, audience, algorithm, accepted issuers, and clock skew' do
    Legion::Settings[:llm][:fleet] = {
      auth: {
        issuer:                 'custom-issuer',
        accepted_issuers:       %w[custom-issuer alternate-issuer],
        audience:               'custom-audience',
        algorithm:              'HS512',
        max_clock_skew_seconds: 90
      }
    }
    Legion::Crypt::JWT.claims = claims.merge(
      iss: 'alternate-issuer',
      aud: 'custom-audience',
      exp: Time.now.to_i - 30,
      nbf: Time.now.to_i + 30
    )

    described_class.validate!(token: 'jwt-token', envelope: envelope)

    expect(Legion::Crypt::JWT.last_verify_options).to include(
      issuer:        'custom-issuer',
      algorithm:     'HS512',
      verify_issuer: true
    )
  end
end
