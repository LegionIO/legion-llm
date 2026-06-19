# frozen_string_literal: true

require 'spec_helper'

RSpec.describe Legion::LLM::Router, '#request_lane (P4)' do
  before { skip 'P4: Router.request_lane' }

  let(:rng) { Random.new(42) }

  def seed_inventory_with(fixture)
    case fixture
    when :vllm_only
      Legion::LLM::Inventory.write_lane(lane: {
                                          id: 'direct:vllm:default:inference:gemma-12b',
        tier: :direct, provider_family: :vllm, instance_id: :default,
        model: 'gemma-12b', type: :inference
                                        })
    when Array
      fixture.each do |lane_attrs|
        provider  = lane_attrs.fetch(:provider, :vllm)
        instance  = lane_attrs.fetch(:instance, :default)
        model     = lane_attrs.fetch(:model, 'gemma-12b')
        tier      = lane_attrs.fetch(:tier, :direct)
        type      = lane_attrs.fetch(:type, :inference)
        weight    = lane_attrs[:lane_weight]
        lane = {
          id:              "#{tier}:#{provider}:#{instance}:#{type}:#{model}",
          tier:            tier,
          provider_family: provider,
          instance_id:     instance,
          model:           model,
          type:            type
        }
        lane[:lane_weight] = weight if weight
        Legion::LLM::Inventory.write_lane(lane: lane)
      end
    end
  end

  it 'returns nil when no lane satisfies hard filters' do
    seed_inventory_with(:vllm_only)
    expect(Legion::LLM::Router.request_lane(type: :inference, providers: [:bedrock], rng: rng)).to be_nil
  end

  it 'filters out lanes with lane_weight <= 0' do
    seed_inventory_with([
                          { provider: :vllm, instance: :a, model: 'gemma-12b', lane_weight: 100_000_000 },
                          { provider: :vllm, instance: :b, model: 'gemma-12b', lane_weight: -100_000_000 }
                        ])
    100.times do
      lane = Legion::LLM::Router.request_lane(type: :inference, rng: rng)
      expect(lane[:instance_id]).to eq(:a)
    end
  end

  it 'excludes tried_lanes' do
    seed_inventory_with([
                          { provider: :vllm, instance: :a, model: 'gemma-12b' },
                          { provider: :vllm, instance: :b, model: 'gemma-12b' }
                        ])
    lane = Legion::LLM::Router.request_lane(
      type: :inference, rng: rng,
      tried_lanes: ['direct:vllm:a:inference:gemma-12b']
    )
    expect(lane[:instance_id]).to eq(:b)
  end

  it 'samples uniformly within the max-weight bucket (seeded determinism)' do
    lanes = 3.times.map do |i|
      { provider: :vllm, instance: :"i#{i}", model: 'gemma-12b', lane_weight: 100_000_000 }
    end
    seed_inventory_with(lanes)
    expect(Legion::LLM::Inventory.lanes_for(provider: :vllm).size).to eq(3)
    picked = 30.times.map { Legion::LLM::Router.request_lane(type: :inference, rng: Random.new(42))[:instance_id] }
    expect(picked.uniq.size).to eq(1)
  end

  it 'spreads across the bucket with different seeds' do
    lanes = 3.times.map do |i|
      { provider: :vllm, instance: :"i#{i}", model: 'gemma-12b', lane_weight: 100_000_000 }
    end
    seed_inventory_with(lanes)
    expect(Legion::LLM::Inventory.lanes_for(provider: :vllm).size).to eq(3)
    picked = 30.times.map { |i| Legion::LLM::Router.request_lane(type: :inference, rng: Random.new(i))[:instance_id] }
    expect(picked.uniq.size).to be > 1
  end

  it 'tier filter is hard (HARD allow-set, not preference)' do
    seed_inventory_with([
                          { tier: :direct, provider: :vllm, model: 'gemma-12b' },
                          { tier: :cloud, provider: :bedrock, model: 'claude-sonnet-4-6' }
                        ])
    expect(Legion::LLM::Router.request_lane(type: :inference, tiers: [:direct], rng: rng)[:tier]).to eq(:direct)
    expect(Legion::LLM::Router.request_lane(type: :inference, tiers: [:cloud],  rng: rng)[:tier]).to eq(:cloud)
  end
end
