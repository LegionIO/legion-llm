# frozen_string_literal: true

require 'spec_helper'

# G21 / opus C1 — pending P1 commit 5
# NOTE: HealthTracker trip-circuit path deleted in SSOT v3 (no health_tracker on Router).
# Health is set via explicit health: kwarg on write_lane; refresher ticks without
# health: preserve the last-written health block (G21 invariant).
RSpec.describe Legion::LLM::Inventory, 'health preservation on refresher write (P1)' do
  before do
    Legion::Settings[:extensions][:llm][:bedrock] ||= {}
    Legion::Settings[:extensions][:llm][:bedrock][:weight]    ||= 100
    Legion::Settings[:extensions][:llm][:bedrock][:instances] ||= {}
    Legion::Settings[:extensions][:llm][:bedrock][:models]    ||= {}
    Legion::LLM::Router.reset! if Legion::LLM::Router.respond_to?(:reset!)
  end

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

  # G21: refresher tick (no health: kwarg) must preserve the open health block that was
  # written by an explicit health: kwarg on the previous tick.
  it 'preserves open-circuit health when refresher writes without explicit health: kwarg (G21)' do
    # First write — set the lane into an open-circuit state explicitly (SSOT v3 path)
    Legion::LLM::Inventory.write_lane(
      lane: build_lane(provider: :bedrock), ttl: 60,
      health: { circuit_state: :open, denied: false, available: false, adjustment: 0 }
    )
    # Refresher tick: write lane without health: kwarg — must preserve the open state
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
