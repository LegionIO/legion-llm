# frozen_string_literal: true

require 'spec_helper'
require 'legion/llm/router/health_tracker'
require 'legion/llm/router'

RSpec.describe Legion::LLM::Router do
  before do
    described_class.reset!
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
      Legion::Settings.set_prop(:llm, Legion::Settings[:llm].merge(
                                        routing: {
                                          enabled: true,
                                          health:  {
                                            window_seconds:  42,
                                            circuit_breaker: {
                                              failure_threshold: 2,
                                              cooldown_seconds:  15
                                            }
                                          }
                                        }
                                      ))
      described_class.reset!

      tracker = described_class.health_tracker

      expect(tracker.instance_variable_get(:@window_seconds)).to eq(42)
      expect(tracker.instance_variable_get(:@failure_threshold)).to eq(2)
      expect(tracker.instance_variable_get(:@cooldown_seconds)).to eq(15)
    end
  end

  # ─── 12. routing_enabled? false when disabled ─────────────────────────────────

  describe '.routing_enabled? when disabled' do
    it 'returns false when enabled is false' do
      Legion::Settings.set_prop(:llm, Legion::Settings[:llm].merge(routing: { enabled: false }))
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

    it 'stays false after populate_auto_rules (no-op in P4 — rule engine removed)' do
      described_class.populate_auto_rules({})
      expect(described_class.auto_rules_populated?).to be false
    end

    it 'returns false after reset!' do
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
end
