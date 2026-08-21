# frozen_string_literal: true

require 'spec_helper'
require 'legion/llm/router'

RSpec.describe Legion::LLM::Router do
  # L1: no rule-list state to reset — the SSOT selector reads the shared
  # owners directly (the former reset! existed only for the auto-rules ivars).

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

  # L1: the auto-rules era surface (auto_rules_populated?, populate_auto_rules,
  # reset!) is gone with the second-selection-domain cleanup — the SSOT
  # selector reads the shared owners directly and has no rule-list state.

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
