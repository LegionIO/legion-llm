# frozen_string_literal: true

require 'spec_helper'
require 'legion/llm/settings/router'

RSpec.describe Legion::LLM::Settings::Router do
  # ------------------------------------------------------------------ #
  # Individual key defaults                                             #
  # ------------------------------------------------------------------ #

  describe 'individual defaults' do
    it 'defaults body_model_hint_whitelist to an empty array' do
      expect(described_class.body_model_hint_whitelist).to eq([])
    end

    it 'defaults body_model_hint_blacklist to an empty array' do
      expect(described_class.body_model_hint_blacklist).to eq([])
    end

    it 'defaults model_passthrough_ids to copilot-utility-small' do
      expect(described_class.model_passthrough_ids).to eq(%w[copilot-utility-small])
    end

    it 'defaults auto_routing_model_aliases to the you-pick aliases' do
      expect(described_class.auto_routing_model_aliases).to eq(%w[legionio auto copilot-utility-small])
    end

    it 'defaults auto_routing_model_alias_metadata with copilot-utility-small owned_by legionio' do
      expect(described_class.auto_routing_model_alias_metadata).to eq(
        'copilot-utility-small' => { owned_by: 'legionio' }
      )
    end

    it 'defaults tier_priority to local, direct, fleet, cloud, frontier' do
      expect(described_class.tier_priority).to eq(%i[local direct fleet cloud frontier])
    end

    it 'defaults fleet_dispatch_enabled to true' do
      expect(described_class.fleet_dispatch_enabled).to be(true)
    end

    it 'defaults max_attempts to 3' do
      expect(described_class.max_attempts).to eq(3)
    end

    it 'defaults affinity_strength_bps to 10_000' do
      expect(described_class.affinity_strength_bps).to eq(10_000)
    end

    it 'defaults input_framing_overhead_tokens to 1_024' do
      expect(described_class.input_framing_overhead_tokens).to eq(1_024)
    end

    it 'defaults context_headroom_ppm to 900_000' do
      expect(described_class.context_headroom_ppm).to eq(900_000)
    end

    it 'defaults allow_body_routing_hints to false' do
      expect(described_class.allow_body_routing_hints).to be(false)
    end
  end

  # ------------------------------------------------------------------ #
  # .defaults aggregate                                                 #
  # ------------------------------------------------------------------ #

  describe '.defaults' do
    subject(:defaults) { described_class.defaults }

    it 'returns a Hash' do
      expect(defaults).to be_a(Hash)
    end

    it 'contains exactly 12 keys' do
      expect(defaults.keys.size).to eq(12)
    end

    it 'maps all keys to their documented default values' do
      expect(defaults).to eq(
        body_model_hint_whitelist:         [],
        body_model_hint_blacklist:         [],
        model_passthrough_ids:             %w[copilot-utility-small],
        auto_routing_model_aliases:        %w[legionio auto copilot-utility-small],
        auto_routing_model_alias_metadata: { 'copilot-utility-small' => { owned_by: 'legionio' } },
        tier_priority:                     %i[local direct fleet cloud frontier],
        fleet_dispatch_enabled:            true,
        max_attempts:                      3,
        affinity_strength_bps:             10_000,
        input_framing_overhead_tokens:     1_024,
        context_headroom_ppm:              900_000,
        allow_body_routing_hints:          false
      )
    end
  end
end
