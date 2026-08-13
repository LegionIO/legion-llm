# frozen_string_literal: true

require 'spec_helper'
require 'legion/llm/router'

RSpec.describe Legion::LLM::Router do
  before do
    described_class.reset!
  end

  # ─── routing_enabled? always false in SSOT v3 ────────────────────────────────

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
