# frozen_string_literal: true

require 'spec_helper'

RSpec.describe Legion::LLM::Inference::Request do
  describe '.build' do
    it 'creates a request with defaults' do
      req = described_class.build(messages: [{ role: :user, content: 'hello' }])
      expect(req.id).to start_with('req_')
      expect(req.schema_version).to eq('1.0.0')
      # 0.8.0: inbound messages are canonicalized to Canonical::Message at the entry.
      expect(req.messages).to all(be_a(Legion::Extensions::Llm::Canonical::Message))
      expect(req.messages.first.role).to eq(:user)
      expect(req.messages.first.content).to eq('hello')
      expect(req.routing).to eq({ provider: nil, model: nil })
      expect(req.tokens).to eq({ max: 4096 })
      expect(req.priority).to eq(:normal)
      expect(req.stream).to eq(false)
      expect(req.caller).to be_nil
      expect(req.enrichments).to eq({})
      expect(req.predictions).to eq({})
      expect(req.frozen?).to eq(true)
    end

    it 'accepts all schema fields' do
      req = described_class.build(
        messages:       [{ role: :user, content: 'test' }],
        system:         'You are helpful.',
        routing:        { provider: :claude, model: 'claude-opus-4-6' },
        tokens:         { max: 8192 },
        caller:         { requested_by: { identity: 'user:matt', type: :user, credential: :session } },
        classification: { level: :internal, contains_pii: false, contains_phi: false },
        priority:       :high,
        stream:         true
      )
      expect(req.system).to eq('You are helpful.')
      expect(req.routing[:provider]).to eq(:claude)
      expect(req.tokens[:max]).to eq(8192)
      expect(req.caller[:requested_by][:identity]).to eq('user:matt')
      expect(req.priority).to eq(:high)
      expect(req.stream).to eq(true)
    end

    it 'generates unique IDs' do
      req1 = described_class.build(messages: [])
      req2 = described_class.build(messages: [])
      expect(req1.id).not_to eq(req2.id)
    end

    it 'normalizes the LegionIO placeholder model into automatic routing when no routing preference is present' do
      req = described_class.build(
        messages: [{ role: :user, content: 'hello' }],
        routing:  { model: 'LegionIO' }
      )

      expect(req.routing).to eq({ model: nil })
      expect(req.extra[:intent]).to include(operation: :chat)
      expect(req.extra[:auto_route]).to be(true)
      expect(req.extra[:requested_model_alias]).to eq('legionio')
    end

    it 'ignores the LegionIO placeholder model without erasing routing preferences' do
      req = described_class.build(
        messages: [{ role: :user, content: 'hello' }],
        routing:  { provider: 'anthropic', instance: 'apollo', model: 'LegionIO' },
        extra:    { tier: 'frontier' }
      )

      expect(req.routing).to eq({ provider: 'anthropic', instance: 'apollo', model: nil })
      expect(req.extra[:tier]).to eq('frontier')
      expect(req.extra[:intent]).to be_nil
      expect(req.extra[:auto_route]).to be_nil
      expect(req.extra[:requested_model_alias]).to eq('legionio')
    end

    it 'treats auto as an automatic routing alias' do
      req = described_class.build(
        messages: [{ role: :user, content: 'hello' }],
        routing:  { model: 'auto' }
      )

      expect(req.routing).to eq({ model: nil })
      expect(req.extra[:auto_route]).to be(true)
      expect(req.extra[:requested_model_alias]).to eq('legionio')
    end

    it 'honors overridden auto model aliases from the canonical [:llm][:router] settings' do
      # SSOT v4: ingress normalization reads auto_routing_model_aliases from the
      # SAME [:llm][:router] home the Router/Filter read — not the legacy
      # [:llm][:routing] tree. A custom alias configured there is recognized here.
      Legion::Settings[:llm][:router][:auto_routing_model_aliases] = %w[legionio autobot]
      req = described_class.build(
        messages: [{ role: :user, content: 'hello' }],
        routing:  { model: 'autobot' }
      )

      expect(req.routing).to eq({ model: nil })
      expect(req.extra[:auto_route]).to be(true)
      expect(req.extra[:requested_model_alias]).to eq('legionio')
    end
  end

  describe '.from_chat_args' do
    it 'builds request from legacy chat() kwargs' do
      req = described_class.from_chat_args(
        message:  'hello',
        model:    'claude-opus-4-6',
        provider: :anthropic,
        intent:   { privacy: :strict }
      )
      expect(req.messages.last.content).to eq('hello')
      expect(req.routing[:model]).to eq('claude-opus-4-6')
      expect(req.routing[:provider]).to eq(:anthropic)
      expect(req.extra[:intent]).to eq({ privacy: :strict })
    end

    it 'uses request_id as the pipeline request id' do
      req = described_class.from_chat_args(
        message:    'hello',
        request_id: 'req_api_123'
      )

      expect(req.id).to eq('req_api_123')
      expect(req.extra).not_to have_key(:request_id)
    end
  end

  describe '.default_auto_routing_intent' do
    # Regression (C15): a stale default_intent[:capability] (the pre-rename shipped
    # default) must be tolerated on the daemon auto-routing path, not raise on every call.
    it 'tolerates a legacy capability: key in settings default_intent' do
      Legion::Settings.set_prop(:llm, Legion::Settings[:llm].merge(
                                        routing: { default_intent: { privacy: 'normal', capability: 'moderate' } }
                                      ))

      intent = nil
      expect { intent = described_class.default_auto_routing_intent }.not_to raise_error
      expect(intent).to include(operation: :chat, effort: :moderate)
    end
  end
end
