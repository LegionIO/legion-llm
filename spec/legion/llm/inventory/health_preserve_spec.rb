# frozen_string_literal: true

require 'spec_helper'

# G21 / opus C1 — pending P1 commit 5
RSpec.describe Legion::LLM::Inventory, 'health preservation on refresher write (P1)' do
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

  it 'preserves existing-lane health when refresher writes without explicit health: kwarg',
     pending: 'P2: HealthTracker must write to Inventory for this test (wired in P2)' do
    Legion::LLM::Inventory.write_lane(lane: build_lane(provider: :bedrock), ttl: 60)
    until Legion::LLM::Inventory.lane(id: 'cloud:bedrock:default:inference:claude-sonnet-4-6')&.dig(:health, :circuit_state) == :open
      Legion::LLM::Router.health_tracker.report(provider: :bedrock, instance: :default, signal: :error)
    end
    Legion::LLM::Inventory.write_lane(lane: build_lane(provider: :bedrock), ttl: 60)
    lane = Legion::LLM::Inventory.lane(id: 'cloud:bedrock:default:inference:claude-sonnet-4-6')
    expect(lane[:health][:circuit_state]).to eq(:open)
  end

  it 'overwrites health when caller passes explicit health: kwarg (HealthTracker path)' do
    Legion::LLM::Inventory.write_lane(lane: build_lane(provider: :bedrock), ttl: 60)
    Legion::LLM::Inventory.write_lane(
      lane: build_lane(provider: :bedrock), ttl: 60,
      health: { circuit_state: :open, denied: false, available: false, adjustment: -50 }
    )
    lane = Legion::LLM::Inventory.lane(id: 'cloud:bedrock:default:inference:claude-sonnet-4-6')
    expect(lane[:health][:circuit_state]).to eq(:open)
  end
end
