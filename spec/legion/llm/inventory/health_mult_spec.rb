# frozen_string_literal: true

require 'spec_helper'

# G23 / sonnet B2
# NOTE: HealthTracker.deny_model is deleted in SSOT v3. Denied health is written via
# explicit health: kwarg on write_lane. The G23 invariant — denied lanes carry
# lane_weight < 0 with magnitude preserved (NOT zeroed) — is asserted below.
RSpec.describe Legion::LLM::Inventory, 'denied lane_weight magnitude preserved (P1)' do
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

  it 'denied health passed explicitly via write_lane gives lane_weight < 0 with magnitude preserved (G23)' do
    Legion::LLM::Inventory.write_lane(
      lane: build_lane(provider: :bedrock), ttl: 60,
      health: { circuit_state: :closed, denied: true, available: false, adjustment: 0 }
    )
    lane = Legion::LLM::Inventory.lane(id: 'cloud:bedrock:default:inference:claude-sonnet-4-6')
    expect(lane[:lane_weight]).to be < 0
    expect(lane[:health][:denied]).to be true
  end
end
