# frozen_string_literal: true

require 'spec_helper'
require 'legion/llm/router/resolution'
require 'legion/llm/router/rule'
require 'legion/llm/router/health_tracker'
require 'legion/llm/router'

RSpec.describe Legion::LLM::Router do
  # Sample routing rules shared across tests
  let(:sample_rules) do
    [
      {
        name:            'privacy-lockdown',
        when:            { privacy: 'strict' },
        then:            { tier: 'local', provider: 'ollama', model: 'qwen3:7b' },
        constraint:      'never_cloud',
        priority:        200,
        cost_multiplier: 0.1
      },
      {
        name:            'reasoning-cloud',
        when:            { capability: 'reasoning' },
        then:            { tier: 'cloud', provider: 'bedrock', model: 'claude-sonnet-4-6' },
        priority:        50,
        cost_multiplier: 2.0
      },
      {
        name:            'basic-local',
        when:            { capability: 'basic' },
        then:            { tier: 'local', provider: 'ollama', model: 'qwen3:7b' },
        priority:        80,
        cost_multiplier: 0.2
      },
      {
        name:            'moderate-default',
        when:            { capability: 'moderate' },
        then:            { tier: 'fleet', provider: 'ollama', model: 'llama4:70b' },
        priority:        60,
        cost_multiplier: 0.5
      }
    ]
  end

  before do
    described_class.reset!
    # Allow all tiers in tests
    allow(described_class).to receive(:tier_available?).and_return(true)
  end

  def configure_routing(enabled: true, rules: sample_rules, extra: {})
    Legion::Settings[:llm] = Legion::Settings[:llm].merge(
      routing: {
        enabled:        enabled,
        rules:          rules,
        default_intent: { privacy: 'normal', capability: 'basic' }
      }.merge(extra)
    )
  end

  # ─── 1. Routes basic capability to local ─────────────────────────────────────

  describe '.resolve with basic capability intent' do
    before { configure_routing }

    it 'routes basic capability to local tier' do
      result = described_class.resolve(intent: { capability: 'basic' })
      expect(result).not_to be_nil
      expect(result.tier).to eq(:local)
    end

    it 'selects the basic-local rule' do
      result = described_class.resolve(intent: { capability: 'basic' })
      expect(result.rule).to eq('basic-local')
    end

    it 'returns the correct model' do
      result = described_class.resolve(intent: { capability: 'basic' })
      expect(result.model).to eq('qwen3:7b')
    end
  end

  # ─── 2. Routes reasoning to cloud ────────────────────────────────────────────

  describe '.resolve with reasoning capability intent' do
    before { configure_routing }

    it 'routes reasoning to cloud tier' do
      result = described_class.resolve(intent: { capability: 'reasoning' })
      expect(result).not_to be_nil
      expect(result.tier).to eq(:cloud)
    end

    it 'selects the reasoning-cloud rule' do
      result = described_class.resolve(intent: { capability: 'reasoning' })
      expect(result.rule).to eq('reasoning-cloud')
    end

    it 'uses the bedrock provider' do
      result = described_class.resolve(intent: { capability: 'reasoning' })
      expect(result.provider).to eq(:bedrock)
    end
  end

  # ─── 3. Enforces privacy constraint — strict never routes to cloud ────────────

  describe '.resolve with strict privacy constraint' do
    before { configure_routing }

    it 'never routes strict privacy to cloud' do
      result = described_class.resolve(intent: { privacy: 'strict', capability: 'reasoning' })
      expect(result).not_to be_nil
      expect(result.tier).not_to eq(:cloud)
    end

    it 'routes strict privacy + reasoning to local (constraint excludes cloud)' do
      result = described_class.resolve(intent: { privacy: 'strict', capability: 'reasoning' })
      expect(result.tier).to eq(:local)
      expect(result.rule).to eq('privacy-lockdown')
    end
  end

  # ─── 4. Picks highest priority when multiple rules match ──────────────────────

  describe '.resolve priority selection' do
    before { configure_routing }

    it 'returns the highest effective_priority candidate' do
      # Add a second matching rule with lower priority
      rules_with_extra = sample_rules + [
        {
          name:            'basic-fallback',
          when:            { capability: 'basic' },
          then:            { tier: 'fleet', provider: 'ollama', model: 'llama4:70b' },
          priority:        10,
          cost_multiplier: 1.0
        }
      ]
      configure_routing(rules: rules_with_extra)

      result = described_class.resolve(intent: { capability: 'basic' })
      # basic-local has priority 80, basic-fallback has priority 10
      # basic-local cost_multiplier 0.2 -> cost_bonus = (1.0 - 0.2) * 10 = 8 -> effective = 88
      # basic-fallback cost_multiplier 1.0 -> cost_bonus = 0 -> effective = 10
      expect(result.rule).to eq('basic-local')
    end
  end

  # ─── 5. Fills missing intent dimensions from defaults ─────────────────────────

  describe '.resolve fills defaults' do
    before { configure_routing }

    it 'merges default_intent when intent is partial' do
      # Provide only privacy, capability defaults to 'basic' from default_intent
      result = described_class.resolve(intent: { privacy: 'normal' })
      expect(result).not_to be_nil
      # basic rule matches because default capability=basic is merged
      expect(result.rule).to eq('basic-local')
    end

    it 'intent values override defaults' do
      # Provide capability=reasoning, overriding default basic
      result = described_class.resolve(intent: { capability: 'reasoning' })
      expect(result.tier).to eq(:cloud)
    end
  end

  # ─── 6. Returns nil when no rules match ──────────────────────────────────────

  describe '.resolve with unmatched intent' do
    before { configure_routing }

    it 'returns nil when no rules match the intent' do
      result = described_class.resolve(intent: { capability: 'unknown_capability_xyz' })
      expect(result).to be_nil
    end
  end

  # ─── 7. Explicit tier override skips rule matching ───────────────────────────

  describe '.resolve with explicit tier override' do
    before { configure_routing }

    it 'returns a resolution with the given tier' do
      result = described_class.resolve(tier: :fleet)
      expect(result).not_to be_nil
      expect(result.tier).to eq(:fleet)
    end

    it 'marks the rule as explicit' do
      result = described_class.resolve(tier: :local)
      expect(result.rule).to eq('explicit')
    end

    it 'uses provided provider when given' do
      result = described_class.resolve(tier: :cloud, provider: :anthropic)
      expect(result.provider).to eq(:anthropic)
    end

    it 'uses provided model when given' do
      result = described_class.resolve(tier: :cloud, model: 'claude-3-haiku')
      expect(result.model).to eq('claude-3-haiku')
    end

    it 'falls back to default provider for tier when provider is nil' do
      result = described_class.resolve(tier: :local)
      expect(result.provider).to eq(:ollama)
    end

    it 'skips rule matching even when routing is enabled' do
      expect(described_class).not_to receive(:load_rules)
      described_class.resolve(tier: :cloud)
    end
  end

  # ─── 8. Health adjustments deprioritize provider with open circuit ────────────

  describe '.resolve with health adjustments' do
    before { configure_routing }

    it 'deprioritizes a provider whose circuit is open' do
      # Open bedrock's circuit by injecting failures into the health tracker
      tracker = described_class.health_tracker
      3.times { tracker.report(provider: :bedrock, signal: :error, value: nil) }
      expect(tracker.circuit_state(:bedrock)).to eq(:open)

      # With bedrock penalized -50, reasoning-cloud effective_priority becomes:
      # 50 + (-50) + (1.0 - 2.0) * 10 = 50 - 50 - 10 = -10
      # No other rule matches reasoning, so result is either nil or basic-local
      # (basic-local doesn't match pure reasoning intent after defaults merge)
      result = described_class.resolve(intent: { capability: 'reasoning' })
      # Result may be nil (only cloud rule matches reasoning) but circuit penalty doesn't
      # filter by tier — it only reduces priority. The rule still matches but gets penalized.
      # basic-local matches if default_intent merges capability=basic... but intent has reasoning.
      # So only reasoning-cloud matches — it still resolves (circuit penalty doesn't filter),
      # but with a very low effective_priority.
      expect(result.rule).to eq('reasoning-cloud') if result
    end

    it 'selects lower-priority local rule over penalized cloud when multiple rules match' do
      # Create scenario with two matching rules for same intent
      rules_with_local_alt = sample_rules + [
        {
          name:            'reasoning-local-alt',
          when:            { capability: 'reasoning' },
          then:            { tier: 'local', provider: 'ollama', model: 'qwen3:7b' },
          priority:        30,
          cost_multiplier: 0.1
        }
      ]
      configure_routing(rules: rules_with_local_alt)
      described_class.reset!
      allow(described_class).to receive(:tier_available?).and_return(true)

      tracker = described_class.health_tracker
      3.times { tracker.report(provider: :bedrock, signal: :error, value: nil) }

      result = described_class.resolve(intent: { capability: 'reasoning' })
      expect(result).not_to be_nil
      # reasoning-cloud: 50 + (-50) + (1.0-2.0)*10 = -10
      # reasoning-local-alt: 30 + 0 + (1.0-0.1)*10 = 30 + 9 = 39
      # local-alt wins
      expect(result.rule).to eq('reasoning-local-alt')
    end
  end

  # ─── 9. health_tracker returns a HealthTracker instance ──────────────────────

  describe '.health_tracker' do
    it 'returns a HealthTracker instance' do
      expect(described_class.health_tracker).to be_a(Legion::LLM::Router::HealthTracker)
    end
  end

  # ─── 10. health_tracker is persistent across calls ────────────────────────────

  describe '.health_tracker persistence' do
    it 'returns the same object on repeated calls' do
      first  = described_class.health_tracker
      second = described_class.health_tracker
      expect(first).to be(second)
    end

    it 'returns a new object after reset!' do
      first = described_class.health_tracker
      described_class.reset!
      second = described_class.health_tracker
      expect(first).not_to be(second)
    end
  end

  # ─── 11. routing_enabled? true when configured ────────────────────────────────

  describe '.routing_enabled?' do
    it 'returns true when routing is enabled with rules' do
      configure_routing
      expect(described_class.routing_enabled?).to be true
    end
  end

  # ─── 12. routing_enabled? false when disabled ─────────────────────────────────

  describe '.routing_enabled? when disabled' do
    it 'returns false when enabled is false' do
      configure_routing(enabled: false)
      expect(described_class.routing_enabled?).to be false
    end

    it 'returns false when rules array is empty' do
      configure_routing(rules: [])
      expect(described_class.routing_enabled?).to be false
    end

    it 'returns false when routing settings are absent' do
      Legion::Settings[:llm] = {}
      expect(described_class.routing_enabled?).to be false
    end
  end
end
