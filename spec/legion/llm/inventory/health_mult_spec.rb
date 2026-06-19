# frozen_string_literal: true

require 'spec_helper'

# G23 / sonnet B2 — pending P1 commit 5
RSpec.describe Legion::LLM::Inventory, 'denied lane_weight magnitude preserved (P1)' do
  before { skip 'P1: Inventory live store' }

  def build_lane(provider: :bedrock, tier: :cloud, model: 'claude-sonnet-4-6')
    {
      id:              "#{tier}:#{provider}:default:inference:#{model}",
      tier:            tier,
      provider_family: provider,
      instance_id:     :default,
      model:           model,
      type:            :inference
    }
  end

  it 'denied lane has lane_weight <= 0 with full magnitude preserved (not zero)' do
    Legion::LLM::Inventory.write_lane(lane: build_lane(provider: :bedrock), ttl: 60)
    Legion::LLM::Router.health_tracker.deny_model(
      provider: :bedrock, instance: :default,
      model: 'claude-sonnet-4-6', reason: :access_denied
    )
    lane = Legion::LLM::Inventory.lane(id: 'cloud:bedrock:default:inference:claude-sonnet-4-6')
    expect(lane[:lane_weight]).to be < 0
    expect(lane[:lane_weight].abs).to eq(100_000_000)
    expect(lane[:health][:denied]).to be true
  end
end
