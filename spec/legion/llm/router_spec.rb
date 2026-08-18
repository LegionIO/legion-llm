# frozen_string_literal: true

require 'spec_helper'
require 'legion/llm/router'

RSpec.describe Legion::LLM::Router do
  before do
    described_class.reset!
  end

  # ─── routing_enabled? is derived: true iff the Registry holds at least one
  # complete publication (SSOT has no operator routing toggle) ─────────────────

  describe '.routing_enabled?' do
    it 'returns false when the Registry has no complete publications' do
      expect(described_class.routing_enabled?).to be false
    end

    it 'returns false for an initializing (unactivated) claim' do
      SsotV3SnapshotFactory.claim_only(provider_family: :vllm, instance_id: 'primary')
      expect(described_class.routing_enabled?).to be false
    end

    it 'returns true once an instance has a complete publication' do
      SsotV3SnapshotFactory.activate(
        provider_family: :vllm, instance_id: 'primary',
        drafts: [SsotV3SnapshotFactory.offering_draft(model: 'gemma-12b', tier: :local, supported: %i[chat])]
      )
      expect(described_class.routing_enabled?).to be true
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
