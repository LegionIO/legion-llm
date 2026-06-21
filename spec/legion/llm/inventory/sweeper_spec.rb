# frozen_string_literal: true

require 'spec_helper'

RSpec.describe Legion::LLM::Inventory::Sweeper do
  def build_lane(provider: :vllm, model: 'gemma-12b', tier: :direct)
    {
      id:              "#{tier}:#{provider}:default:inference:#{model}",
      tier:            tier,
      provider_family: provider,
      instance_id:     :default,
      model:           model,
      type:            :inference
    }
  end

  it 'drops lanes whose expires_at is in the past (no real sleep — stub expired_ids)' do
    lane_id = 'direct:vllm:default:inference:gemma-12b'
    Legion::LLM::Inventory.write_lane(lane: build_lane(provider: :vllm), ttl: 60)
    expect(Legion::LLM::Inventory.lane(id: lane_id)).not_to be_nil

    # Simulate expiry by directly stubbing expired_ids (no Timecop needed)
    allow(Legion::LLM::Inventory).to receive(:expired_ids).and_return([lane_id])
    described_class.sweep!

    expect(Legion::LLM::Inventory.lane(id: lane_id)).to be_nil
  end

  it 'never drops lanes with expires_at: nil (static-catalog)' do
    lane_id = 'frontier:anthropic:default:inference:claude-sonnet-4-6'
    Legion::LLM::Inventory.write_lane(lane: build_lane(provider: :anthropic, tier: :frontier, model: 'claude-sonnet-4-6'))

    # No expired lanes — stub returns empty
    allow(Legion::LLM::Inventory).to receive(:expired_ids).and_return([])
    described_class.sweep!

    expect(Legion::LLM::Inventory.lane(id: lane_id)).not_to be_nil
  end

  it 'iterates via Inventory.expired_ids — never via .send(:map) (M3)' do
    src = File.read('lib/legion/llm/inventory/sweeper.rb')
    expect(src).not_to match(/Inventory\.send\(:map\)/)
    expect(src).to match(/Inventory\.expired_ids/)
  end
end
