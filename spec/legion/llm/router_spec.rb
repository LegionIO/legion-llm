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
        then:            { tier: 'local', provider: 'ollama', model: 'qwen3:7b', effort: 'low' },
        constraint:      'never_cloud',
        priority:        200,
        cost_multiplier: 0.1
      },
      {
        name:            'reasoning-cloud',
        when:            { effort: 'reasoning' },
        then:            { tier: 'cloud', provider: 'bedrock', model: 'claude-sonnet-4-6', effort: 'reasoning' },
        priority:        50,
        cost_multiplier: 2.0
      },
      {
        name:            'chat-local',
        when:            { operation: 'chat', effort: 'low' },
        then:            { tier: 'local', provider: 'ollama', model: 'qwen3:7b', effort: 'low' },
        priority:        80,
        cost_multiplier: 0.2
      },
      {
        name:            'moderate-default',
        when:            { effort: 'moderate' },
        then:            { tier: 'fleet', provider: 'ollama', model: 'llama4:70b', effort: 'moderate' },
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

  def configure_routing(enabled: true, rules: sample_rules, extra: {}, auto_rules_populated: true, default_intent: { privacy: 'normal', effort: 'moderate', operation: 'chat' })
    Legion::Settings.set_prop(:llm, Legion::Settings[:llm].merge(
                                      routing: {
                                        enabled:        enabled,
                                        rules:          rules,
                                        default_intent: default_intent
                                      }.merge(extra)
                                    ))
    described_class.populate_auto_rules({}) if auto_rules_populated && enabled
  end

  # ─── 1. Routes chat operation to local ─────────────────────────────────────

  describe '.resolve with chat operation intent' do
    before { configure_routing }

    it 'routes chat operation to local tier' do
      result = described_class.resolve(intent: { operation: :chat, effort: :low })
      expect(result).not_to be_nil
      expect(result.tier).to eq(:local)
    end

    it 'selects the chat-local rule' do
      result = described_class.resolve(intent: { operation: :chat, effort: :low })
      expect(result.rule).to eq('chat-local')
    end

    it 'returns the correct model' do
      result = described_class.resolve(intent: { operation: :chat, effort: :low })
      expect(result.model).to eq('qwen3:7b')
    end

    it 'uses a provider hint as the primary candidate instead of a higher-scored different provider' do
      configured_rules = sample_rules + [
        {
          name:            'chat-bedrock',
          when:            { operation: 'chat', effort: 'low' },
          then:            { tier: 'cloud', provider: 'bedrock', model: 'anthropic.claude-sonnet-4-6', effort: 'high' },
          priority:        1,
          cost_multiplier: 2.0
        }
      ]
      configure_routing(rules: configured_rules)

      result = described_class.resolve(intent: { operation: :chat, effort: :low }, provider: :bedrock)

      expect(result.provider).to eq(:bedrock)
      expect(result.rule).to eq('chat-bedrock')
    end

    it 'falls through to explicit resolution when hinted provider is registered but has no rules' do
      result = described_class.resolve(intent: { operation: :chat, effort: :low }, provider: :openai)

      expect(result.provider).to eq(:openai)
      expect(result.rule).to eq('explicit')
    end

    it 'uses normal scoring when hinted provider is not registered' do
      allow(Legion::LLM::Call::Registry).to receive(:registered?).with(:fakeprovider).and_return(false)

      result = described_class.resolve(intent: { operation: :chat, effort: :low }, provider: :fakeprovider)

      expect(result.provider).to eq(:ollama)
      expect(result.rule).to eq('chat-local')
    end
  end

  # ─── 2. Routes reasoning effort to cloud ────────────────────────────────────────────

  describe '.resolve with reasoning effort intent' do
    before { configure_routing }

    it 'routes reasoning effort to cloud tier' do
      result = described_class.resolve(intent: { effort: :reasoning })
      expect(result).not_to be_nil
      expect(result.tier).to eq(:cloud)
    end

    it 'selects the reasoning-cloud rule' do
      result = described_class.resolve(intent: { effort: :reasoning })
      expect(result.rule).to eq('reasoning-cloud')
    end

    it 'uses the bedrock provider' do
      result = described_class.resolve(intent: { effort: :reasoning })
      expect(result.provider).to eq(:bedrock)
    end
  end

  # ─── 3. Enforces privacy constraint — strict never routes to cloud ────────────

  describe '.resolve with strict privacy constraint' do
    before { configure_routing }

    it 'never routes strict privacy to cloud' do
      result = described_class.resolve(intent: { privacy: :strict, effort: :reasoning })
      expect(result).not_to be_nil
      expect(result.tier).not_to eq(:cloud)
    end

    it 'routes strict privacy + reasoning to local (constraint excludes cloud)' do
      result = described_class.resolve(intent: { privacy: :strict, effort: :reasoning })
      expect(result.tier).to eq(:local)
      expect(result.rule).to eq('privacy-lockdown')
    end
  end

  # ─── 4. Picks highest priority when multiple rules match ──────────────────────

  describe '.resolve priority selection' do
    before { configure_routing }

    it 'returns the highest effective_priority candidate' do
      rules_with_extra = sample_rules + [
        {
          name:            'chat-fallback',
          when:            { operation: 'chat' },
          then:            { tier: 'fleet', provider: 'ollama', model: 'llama4:70b', effort: 'moderate' },
          priority:        10,
          cost_multiplier: 1.0
        }
      ]
      configure_routing(rules: rules_with_extra)

      result = described_class.resolve(intent: { operation: :chat, effort: :low })
      # chat-local has priority 80, chat-fallback has priority 10
      # chat-local cost_multiplier 0.2 -> cost_bonus = 8, effort_bonus = 25 (exact match low) -> effective > chat-fallback
      expect(result.rule).to eq('chat-local')
    end

    it 'requires declared model capabilities when the intent asks for them' do
      rules_with_capabilities = [
        {
          name:     'stream-local-no-tools',
          when:     { operation: 'stream' },
          then:     {
            tier:               'local',
            provider:           'ollama',
            model:              'hf.co/unsloth/Qwen3.6-27B-GGUF:UD-Q4_K_XL',
            model_capabilities: %i[completion streaming]
          },
          priority: 200
        },
        {
          name:     'stream-direct-tools',
          when:     { operation: 'stream' },
          then:     {
            tier:               'direct',
            provider:           'vllm',
            instance:           'apollo',
            model:              'qwen3.6-27b',
            model_capabilities: %i[completion streaming tools]
          },
          priority: 100
        }
      ]
      configure_routing(rules: rules_with_capabilities)

      result = described_class.resolve(intent: { operation: :stream, required_capabilities: %i[tools streaming] })

      expect(result.rule).to eq('stream-direct-tools')
      expect(result.provider).to eq(:vllm)
      expect(result.instance).to eq(:apollo)
    end
  end

  # ─── 5. Fills missing intent dimensions from defaults ─────────────────────────

  describe '.resolve fills defaults' do
    before { configure_routing }

    it 'merges default_intent when intent is partial' do
      result = described_class.resolve(intent: { privacy: :normal })
      expect(result).not_to be_nil
      # moderate-default matches because default effort=moderate is merged
      expect(result.rule).to eq('moderate-default')
    end

    it 'intent values override defaults' do
      result = described_class.resolve(intent: { effort: :reasoning })
      expect(result.tier).to eq(:cloud)
    end
  end

  # ─── 6. Falls back when no rules match ──────────────────────────────────────

  describe '.resolve with unmatched intent' do
    before { configure_routing }

    it 'falls back to explicit resolution or arbitrage when no rules match the intent' do
      result = described_class.resolve(intent: { operation: :embed })
      expect(result).not_to be_nil
    end
  end

  # ─── 7. Explicit tier override as preference hint ───────────────────────────

  describe '.resolve with explicit tier override' do
    before do
      # Configure with empty rules so tier/provider hints
      # fall through to explicit resolution rather than matching rules
      configure_routing(rules: [])
    end

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

    it 'falls back to the provider registry instance when an explicit instance is not registered for that provider' do
      Legion::LLM::Call::Registry.register(:vllm, Module.new, instance: :apollo)
      Legion::LLM::Call::Registry.register(:anthropic, Module.new, metadata: { default_model: 'claude-sonnet-4-6' })

      result = described_class.resolve(provider: :anthropic, instance: :apollo, model: 'claude-sonnet-4-6')

      expect(result.instance).to eq(:default)
    end

    it 'falls back to default provider for tier when provider is nil' do
      result = described_class.resolve(tier: :local)
      expect(result.provider).to eq(:ollama)
    end

    it 'uses tier/provider as preference hints during rule matching' do
      configure_routing
      result = described_class.resolve(tier: :cloud)
      expect(result).not_to be_nil
    end
  end

  # ─── 8. Health adjustments deprioritize provider with open circuit ────────────

  describe '.resolve with health adjustments' do
    before { configure_routing }

    it 'deprioritizes a provider whose circuit is open' do
      tracker = described_class.health_tracker
      3.times { tracker.report(provider: :bedrock, signal: :error, value: nil) }
      expect(tracker.instance_variable_get(:@circuits)[:bedrock]&.dig(:state)).to eq(:open)

      result = described_class.resolve(intent: { effort: :reasoning })
      # reasoning-cloud still matches but gets penalized heavily
      expect(result.rule).to eq('reasoning-cloud') if result
    end

    it 'selects lower-priority local rule over penalized cloud when multiple rules match' do
      rules_with_local_alt = sample_rules + [
        {
          name:            'reasoning-local-alt',
          when:            { effort: 'reasoning' },
          then:            { tier: 'local', provider: 'ollama', model: 'qwen3:7b', effort: 'reasoning' },
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

      result = described_class.resolve(intent: { effort: :reasoning })
      expect(result).not_to be_nil
      # reasoning-cloud penalized by circuit; reasoning-local-alt wins
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

    it 'infers ollama for colon-pattern model names (ollama tag format)' do
      # After P3, discover_provider_for_model is deleted. colon-separated names
      # (the Ollama "model:tag" format) are inferred as :ollama via OLLAMA_MODEL_PATTERN.
      expect(described_class.infer_provider_for_model('qwen3.6:27b')).to eq(:ollama)
    end

    it 'falls back to static inference when discovery cache is unavailable' do
      stub_const('Legion::LLM::Discovery', Module.new)

      expect(described_class.infer_provider_for_model('qwen3:7b')).to eq(:ollama)
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

    it 'returns false for :local' do
      expect(described_class.send(:external_tier?, :local)).to be false
    end
  end

  # ─── TIER_EXTERNAL constant ─────────────────────────────────────────────────

  describe 'TIER_EXTERNAL' do
    it 'is a frozen Set of external tiers' do
      expect(described_class::TIER_EXTERNAL).to be_a(Set)
      expect(described_class::TIER_EXTERNAL).to be_frozen
      expect(described_class::TIER_EXTERNAL).to eq(Set[:cloud, :frontier])
    end
  end

  # ─── normalize_intent ────────────────────────────────────────────────────────

  describe '.normalize_intent' do
    it 'passes through the new intent shape unchanged' do
      normalized = described_class.send(
        :normalize_intent,
        { privacy: :normal, effort: :moderate, cost: :normal, operation: :chat, required_capabilities: [:tools] }
      )

      expect(normalized).to include(
        privacy:               :normal,
        effort:                :moderate,
        cost:                  :normal,
        operation:             :chat,
        required_capabilities: [:tools]
      )
      expect(normalized).not_to have_key(:capability)
    end

    it 'preserves effort: :high' do
      expect(described_class.send(:normalize_intent, { effort: :high, operation: :chat })[:effort]).to eq(:high)
    end

    it 'normalizes effort: :medium to :moderate' do
      expect(described_class.send(:normalize_intent, { effort: :medium })[:effort]).to eq(:moderate)
    end

    it 'preserves model passthrough in intent' do
      expect(described_class.send(:normalize_intent, { operation: 'chat', model: 'custom-model' })[:model]).to eq('custom-model')
    end

    # Regression (C15): the removed :capability dimension must be tolerated (ignored),
    # not raised on — a stale key in settings or caller intent previously bricked routing.
    it 'tolerates a legacy capability: key (ignored, not raised)' do
      normalized = nil
      expect { normalized = described_class.send(:normalize_intent, { capability: :moderate }) }.not_to raise_error
      expect(normalized).to include(:operation, :effort)
    end

    it 'raises ArgumentError for unknown effort values' do
      expect do
        described_class.send(:normalize_intent, { effort: :basic })
      end.to raise_error(ArgumentError, /unknown effort/i)
    end

    it 'defaults operation to :chat' do
      normalized = described_class.send(:normalize_intent, { effort: :moderate })
      expect(normalized[:operation]).to eq(:chat)
    end

    it 'defaults effort to :moderate' do
      normalized = described_class.send(:normalize_intent, { operation: :stream })
      expect(normalized[:effort]).to eq(:moderate)
    end

    it 'normalizes string operation values' do
      normalized = described_class.send(:normalize_intent, { operation: 'stream' })
      expect(normalized[:operation]).to eq(:stream)
    end

    it 'normalizes operation aliases' do
      normalized = described_class.send(:normalize_intent, { operation: :completion })
      expect(normalized[:operation]).to eq(:chat)
    end
  end
end
