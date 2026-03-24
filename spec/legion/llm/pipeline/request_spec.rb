# frozen_string_literal: true

require 'spec_helper'

RSpec.describe Legion::LLM::Pipeline::Request do
  describe '.build' do
    it 'creates a request with defaults' do
      req = described_class.build(messages: [{ role: :user, content: 'hello' }])
      expect(req.id).to start_with('req_')
      expect(req.schema_version).to eq('1.0.0')
      expect(req.messages).to eq([{ role: :user, content: 'hello' }])
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
        messages: [{ role: :user, content: 'test' }],
        system: 'You are helpful.',
        routing: { provider: :claude, model: 'claude-opus-4-6' },
        tokens: { max: 8192 },
        caller: { requested_by: { identity: 'user:matt', type: :user, credential: :session } },
        classification: { level: :internal, contains_pii: false, contains_phi: false },
        priority: :high,
        stream: true
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
  end

  describe '.from_chat_args' do
    it 'builds request from legacy chat() kwargs' do
      req = described_class.from_chat_args(
        message: 'hello',
        model: 'claude-opus-4-6',
        provider: :anthropic,
        intent: { privacy: :strict }
      )
      expect(req.messages.last[:content]).to eq('hello')
      expect(req.routing[:model]).to eq('claude-opus-4-6')
      expect(req.routing[:provider]).to eq(:anthropic)
      expect(req.extra[:intent]).to eq({ privacy: :strict })
    end
  end
end
