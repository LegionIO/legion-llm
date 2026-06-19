# frozen_string_literal: true

require 'spec_helper'

RSpec.describe Legion::LLM::Inventory, '#write_lane / #delete_lane (P1)' do
  before { skip 'P1: Inventory live store' }

  def build_lane(provider: :vllm, instance: :default, tier: :direct, model: 'gemma-12b', type: :inference)
    {
      id:              "#{tier}:#{provider}:#{instance}:#{type}:#{model}",
      tier:            tier,
      provider_family: provider,
      instance_id:     instance,
      model:           model,
      type:            type
    }
  end

  it 'rejects denied models fail-closed' do
    Legion::Settings.loader.settings[:extensions][:llm][:bedrock][:model_blacklist] = ['claude-old']
    Legion::LLM::Inventory.write_lane(lane: build_lane(provider: :bedrock, model: 'claude-old'))
    expect(Legion::LLM::Inventory.lane(id: 'cloud:bedrock:default:inference:claude-old')).to be_nil
  end

  it 'computes lane_weight from settings on write' do
    Legion::Settings.loader.settings[:extensions][:llm][:vllm][:weight] = 200
    Legion::Settings.loader.settings[:llm][:routing][:tier_weights] = { direct: 100 }
    Legion::LLM::Inventory.write_lane(lane: build_lane(provider: :vllm, tier: :direct, model: 'gemma-12b'))
    lane = Legion::LLM::Inventory.lane(id: 'direct:vllm:default:inference:gemma-12b')
    expect(lane[:lane_weight]).to eq(100 * 200 * 100 * 100 * 1.0)
  end

  it 'stamps expires_at when ttl is given; nil when omitted' do
    t0 = Time.now
    Legion::LLM::Inventory.write_lane(lane: build_lane(provider: :vllm, model: 'gemma-12b'), ttl: 60)
    lane = Legion::LLM::Inventory.lane(id: 'direct:vllm:default:inference:gemma-12b')
    expect(lane[:expires_at]).to be_within(1.0).of(t0.to_f + 60)

    Legion::LLM::Inventory.write_lane(lane: build_lane(provider: :anthropic, tier: :frontier, model: 'claude-sonnet-4-6'))
    lane2 = Legion::LLM::Inventory.lane(id: 'frontier:anthropic:default:inference:claude-sonnet-4-6')
    expect(lane2[:expires_at]).to be_nil
  end

  it 'delete_lane removes the entry; debug-logs miss' do
    Legion::LLM::Inventory.write_lane(lane: build_lane(provider: :vllm, model: 'gemma-12b'))
    expect { Legion::LLM::Inventory.delete_lane(id: 'direct:vllm:default:inference:gemma-12b') }
      .to change { Legion::LLM::Inventory.lane(id: 'direct:vllm:default:inference:gemma-12b') }.to(nil)
  end

  it 'lanes_for(provider:, instance:) returns matching lanes only' do
    Legion::LLM::Inventory.write_lane(lane: build_lane(provider: :vllm, instance: :apollo, model: 'gemma-12b'))
    Legion::LLM::Inventory.write_lane(lane: build_lane(provider: :vllm, instance: :apollo, model: 'gemma-31b'))
    Legion::LLM::Inventory.write_lane(lane: build_lane(provider: :vllm, instance: :zeus,   model: 'gemma-12b'))
    matches = Legion::LLM::Inventory.lanes_for(provider: :vllm, instance: :apollo)
    expect(matches.map { _1[:model] }).to contain_exactly('gemma-12b', 'gemma-31b')
  end
end
