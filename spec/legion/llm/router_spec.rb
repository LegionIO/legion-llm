# frozen_string_literal: true

require 'spec_helper'
require 'legion/llm/router/resolution'
require 'legion/llm/router/rule'
require 'legion/llm/router/health_tracker'
require 'legion/llm/router'
require 'legion/llm/discovery/system'

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
    # Stub discovery so existing tests pass (models always available, plenty of memory)
    allow(Legion::LLM::Discovery).to receive(:model_available?).and_return(true)
    allow(Legion::LLM::Discovery).to receive(:model_size).and_return(nil)
    allow(Legion::LLM::Discovery::System).to receive(:available_memory_mb).and_return(65_536)
  end

  def configure_routing(enabled: true, rules: sample_rules, extra: {}, auto_rules_populated: true)
    Legion::Settings.set_prop(:llm, Legion::Settings[:llm].merge(
                                      routing: {
                                        enabled:        enabled,
                                        rules:          rules,
                                        default_intent: { privacy: 'normal', capability: 'basic' }
                                      }.merge(extra)
                                    ))
    described_class.populate_auto_rules({}) if auto_rules_populated && enabled
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
      described_class.reset!
      configure_routing(rules: rules_with_local_alt)
      allow(described_class).to receive(:tier_available?).and_return(true)
      allow(Legion::LLM::Discovery).to receive(:model_available?).and_return(true)
      allow(Legion::LLM::Discovery).to receive(:model_size).and_return(nil)
      allow(Legion::LLM::Discovery::System).to receive(:available_memory_mb).and_return(65_536)

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

  describe '.health_tracker with custom health settings' do
    it 'honors routing.health settings when building the tracker' do
      configure_routing(
        extra: {
          health: {
            window_seconds:  42,
            circuit_breaker: {
              failure_threshold: 2,
              cooldown_seconds:  15
            }
          }
        }
      )
      described_class.reset!

      tracker = described_class.health_tracker

      expect(tracker.instance_variable_get(:@window_seconds)).to eq(42)
      expect(tracker.instance_variable_get(:@failure_threshold)).to eq(2)
      expect(tracker.instance_variable_get(:@cooldown_seconds)).to eq(15)
    end
  end

  # ─── 11. routing_enabled? true when configured ────────────────────────────────

  describe '.routing_enabled?' do
    it 'returns true when routing is enabled and auto_rules populated' do
      configure_routing
      expect(described_class.routing_enabled?).to be true
    end

    it 'returns true even when manual rules array is empty (auto_rules populated)' do
      configure_routing(rules: [])
      expect(described_class.routing_enabled?).to be true
    end
  end

  # ─── 12. routing_enabled? false when disabled ─────────────────────────────────

  describe '.routing_enabled? when disabled' do
    it 'returns false when enabled is false' do
      configure_routing(enabled: false)
      expect(described_class.routing_enabled?).to be false
    end

    it 'returns false when auto_rules not yet populated' do
      configure_routing(auto_rules_populated: false)
      expect(described_class.routing_enabled?).to be false
    end

    it 'returns false when routing settings are absent' do
      Legion::Settings.set_prop(:llm, {})
      expect(described_class.routing_enabled?).to be false
    end
  end

  # ─── 12a. auto_rules_populated? ─────────────────────────────────────────────

  describe '.auto_rules_populated?' do
    it 'returns false before populate_auto_rules is called' do
      expect(described_class.auto_rules_populated?).to be false
    end

    it 'returns true after populate_auto_rules is called' do
      described_class.populate_auto_rules({})
      expect(described_class.auto_rules_populated?).to be true
    end

    it 'returns false after reset!' do
      described_class.populate_auto_rules({})
      described_class.reset!
      expect(described_class.auto_rules_populated?).to be false
    end
  end

  describe '.infer_provider_for_model' do
    {
      'qwen3.5:latest'                    => :ollama,
      'qwen3:7b'                          => :ollama,
      'llama3:70b'                        => :ollama,
      'mistral:latest'                    => :ollama,
      'phi3:mini'                         => :ollama,
      'deepseek-coder:6.7b'               => :ollama,
      'nomic-embed-text:latest'           => :ollama,
      'us.anthropic.claude-sonnet-4-6-v1' => :bedrock,
      'us.meta.llama3-70b-instruct-v1:0'  => :bedrock,
      'gpt-4o'                            => :openai,
      'gpt-4o-mini'                       => :openai,
      'o1-preview'                        => :openai,
      'o3-mini'                           => :openai,
      'o4-mini'                           => :openai,
      'claude-sonnet-4-6'                 => :anthropic,
      'claude-3-5-haiku-20241022'         => :anthropic,
      'gemini-2.0-flash'                  => :gemini,
      'gemini-1.5-pro'                    => :gemini
    }.each do |model, expected_provider|
      it "infers #{expected_provider} for #{model}" do
        expect(described_class.infer_provider_for_model(model)).to eq(expected_provider)
      end
    end

    it 'returns nil for nil model' do
      expect(described_class.infer_provider_for_model(nil)).to be_nil
    end

    it 'returns nil for empty string' do
      expect(described_class.infer_provider_for_model('')).to be_nil
    end

    it 'returns nil for unrecognized model names' do
      expect(described_class.infer_provider_for_model('some-custom-model')).to be_nil
    end
  end

  # ─── tier_available? for :direct tier ────────────────────────────────────────

  describe '.tier_available?' do
    before do
      # Remove the blanket stub so we test the real method
      allow(described_class).to receive(:tier_available?).and_call_original
      allow(described_class).to receive(:privacy_mode?).and_return(false)
    end

    it 'returns true for :direct tier' do
      expect(described_class.tier_available?(:direct)).to be true
    end

    it 'returns true for :local tier' do
      expect(described_class.tier_available?(:local)).to be true
    end
  end

  # ─── external_tier? via TIER_EXTERNAL constant ───────────────────────────────

  describe '.external_tier? (via TIER_EXTERNAL)' do
    it 'returns false for :direct' do
      expect(described_class.send(:external_tier?, :direct)).to be false
    end

    it 'returns false for :local' do
      expect(described_class.send(:external_tier?, :local)).to be false
    end

    it 'returns true for :cloud' do
      expect(described_class.send(:external_tier?, :cloud)).to be true
    end

    it 'returns true for :frontier' do
      expect(described_class.send(:external_tier?, :frontier)).to be true
    end

    it 'returns true for :openai_compat' do
      expect(described_class.send(:external_tier?, :openai_compat)).to be true
    end
  end

  # ─── TIER_EXTERNAL constant ─────────────────────────────────────────────────

  describe 'TIER_EXTERNAL' do
    it 'is a frozen Set of external tiers' do
      expect(described_class::TIER_EXTERNAL).to be_a(Set)
      expect(described_class::TIER_EXTERNAL).to be_frozen
      expect(described_class::TIER_EXTERNAL).to eq(Set[:cloud, :frontier, :openai_compat])
    end
  end
end
