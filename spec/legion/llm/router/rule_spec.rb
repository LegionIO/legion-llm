# frozen_string_literal: true

require 'spec_helper'
require 'legion/llm/router/resolution'
require 'legion/llm/router/rule'

RSpec.describe Legion::LLM::Router::Rule do
  let(:rule_hash) do
    {
      name:            :privacy_local,
      when:            { privacy: :high, capability: :chat },
      then:            { tier: :local, provider: :ollama, model: 'llama3' },
      priority:        10,
      constraint:      'privacy_high',
      fallback:        'fleet',
      cost_multiplier: 0.5,
      schedule:        '0 2 * * *',
      note:            'Route high-privacy requests locally'
    }
  end

  subject(:rule) { described_class.from_hash(rule_hash) }

  describe '.from_hash' do
    it 'constructs a Rule with all fields' do
      expect(rule.name).to eq(:privacy_local)
      expect(rule.conditions).to eq({ privacy: :high, capability: :chat })
      expect(rule.target).to eq({ tier: :local, provider: :ollama, model: 'llama3' })
      expect(rule.priority).to eq(10)
      expect(rule.constraint).to eq('privacy_high')
      expect(rule.fallback).to eq(:fleet)
      expect(rule.cost_multiplier).to eq(0.5)
      expect(rule.schedule).to eq('0 2 * * *')
      expect(rule.note).to eq('Route high-privacy requests locally')
    end

    it 'defaults priority to 0 when not provided' do
      r = described_class.from_hash(
        name: :default_rule,
        when: {},
        then: { tier: :cloud, provider: :anthropic, model: 'claude-sonnet-4-6' }
      )
      expect(r.priority).to eq(0)
    end

    it 'defaults cost_multiplier to 1.0 when not provided' do
      r = described_class.from_hash(
        name: :default_rule,
        when: {},
        then: { tier: :cloud, provider: :anthropic, model: 'claude-sonnet-4-6' }
      )
      expect(r.cost_multiplier).to eq(1.0)
    end

    it 'stores fallback as a symbol' do
      expect(rule.fallback).to eq(:fleet)
      expect(rule.fallback).to be_a(Symbol)
    end

    it 'returns nil fallback when not provided' do
      r = described_class.from_hash(
        name: :no_fallback,
        when: {},
        then: { tier: :local, provider: :ollama, model: 'llama3' }
      )
      expect(r.fallback).to be_nil
    end
  end

  describe '#matches_intent?' do
    context 'when all conditions are satisfied' do
      it 'returns true' do
        intent = { privacy: :high, capability: :chat }
        expect(rule.matches_intent?(intent)).to be true
      end
    end

    context 'with string or symbol values' do
      it 'matches when intent uses strings and conditions use symbols' do
        intent = { privacy: 'high', capability: 'chat' }
        expect(rule.matches_intent?(intent)).to be true
      end

      it 'matches when intent uses symbols and conditions use strings' do
        r = described_class.from_hash(
          name: :str_cond,
          when: { privacy: 'high' },
          then: { tier: :local, provider: :ollama, model: 'llama3' }
        )
        expect(r.matches_intent?({ privacy: :high })).to be true
      end
    end

    context 'when a condition key is missing from intent' do
      it 'returns false' do
        intent = { privacy: :high }
        expect(rule.matches_intent?(intent)).to be false
      end
    end

    context 'when a condition value does not match' do
      it 'returns false' do
        intent = { privacy: :low, capability: :chat }
        expect(rule.matches_intent?(intent)).to be false
      end
    end

    context 'with empty conditions (catch-all)' do
      it 'returns true for any intent' do
        r = described_class.from_hash(
          name: :catch_all,
          when: {},
          then: { tier: :cloud, provider: :anthropic, model: 'claude-sonnet-4-6' }
        )
        expect(r.matches_intent?({ privacy: :high, capability: :anything })).to be true
      end

      it 'returns true even for an empty intent' do
        r = described_class.from_hash(
          name: :catch_all,
          when: {},
          then: { tier: :cloud, provider: :anthropic, model: 'claude-sonnet-4-6' }
        )
        expect(r.matches_intent?({})).to be true
      end
    end
  end

  describe '#constraint' do
    it 'returns the constraint string when set' do
      expect(rule.constraint).to eq('privacy_high')
    end

    it 'returns nil when not provided' do
      r = described_class.from_hash(
        name: :no_constraint,
        when: {},
        then: { tier: :local, provider: :ollama, model: 'llama3' }
      )
      expect(r.constraint).to be_nil
    end
  end

  describe '#fallback' do
    it 'returns the fallback tier as a symbol' do
      expect(rule.fallback).to eq(:fleet)
    end
  end

  describe '#cost_multiplier' do
    it 'returns the configured cost multiplier' do
      expect(rule.cost_multiplier).to eq(0.5)
    end

    it 'defaults to 1.0 when not specified' do
      r = described_class.from_hash(
        name: :default_cost,
        when: {},
        then: { tier: :cloud, provider: :anthropic, model: 'claude-sonnet-4-6' }
      )
      expect(r.cost_multiplier).to eq(1.0)
    end
  end

  describe '#to_resolution' do
    it 'creates a Resolution with the correct tier, provider, and model' do
      resolution = rule.to_resolution
      expect(resolution).to be_a(Legion::LLM::Router::Resolution)
      expect(resolution.tier).to eq(:local)
      expect(resolution.provider).to eq(:ollama)
      expect(resolution.model).to eq('llama3')
    end

    it 'sets rule name on the resolution' do
      resolution = rule.to_resolution
      expect(resolution.rule).to eq(:privacy_local)
    end

    it 'includes cost_multiplier and fallback in metadata' do
      resolution = rule.to_resolution
      expect(resolution.metadata[:cost_multiplier]).to eq(0.5)
      expect(resolution.metadata[:fallback]).to eq(:fleet)
    end

    it 'compacts metadata when fallback is nil' do
      r = described_class.from_hash(
        name:            :no_fallback_rule,
        when:            {},
        then:            { tier: :local, provider: :ollama, model: 'llama3' },
        cost_multiplier: 2.0
      )
      resolution = r.to_resolution
      expect(resolution.metadata).to eq({ cost_multiplier: 2.0 })
      expect(resolution.metadata).not_to have_key(:fallback)
    end

    it 'compacts metadata when cost_multiplier is default 1.0' do
      r = described_class.from_hash(
        name:     :default_cost_rule,
        when:     {},
        then:     { tier: :local, provider: :ollama, model: 'llama3' },
        fallback: 'cloud'
      )
      resolution = r.to_resolution
      expect(resolution.metadata[:cost_multiplier]).to eq(1.0)
      expect(resolution.metadata[:fallback]).to eq(:cloud)
    end
  end
end
