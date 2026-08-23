# frozen_string_literal: true

require 'spec_helper'
require 'legion/llm/settings/router'

RSpec.describe Legion::LLM::Settings::Router do
  describe '.defaults' do
    it 'returns the routing defaults' do
      expect(described_class.defaults).to eq(
        body_model_hint_whitelist: [],
        body_model_hint_blacklist: [],
        model_passthrough_ids: %w[copilot-utility-small],
        auto_routing_model_aliases: %w[legionio auto copilot-utility-small],
        auto_routing_model_alias_metadata: { 'copilot-utility-small' => { owned_by: 'legionio' } }
      )
    end
  end

  describe 'individual defaults' do
    it 'defaults body_model_hint_whitelist to an empty array' do
      expect(described_class.body_model_hint_whitelist).to eq([])
    end

    it 'defaults auto_routing_model_aliases to the you-pick aliases' do
      expect(described_class.auto_routing_model_aliases).to eq(%w[legionio auto copilot-utility-small])
    end
  end
end
