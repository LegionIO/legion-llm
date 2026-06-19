# frozen_string_literal: true

require 'spec_helper'

RSpec.describe 'Legion::LLM::Inventory::Sweeper (P1)' do
  before { skip 'P1: TTL sweeper' }

  let(:described_class) { Legion::LLM::Inventory::Sweeper }

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

  it 'drops lanes whose expires_at is in the past' do
    Timecop.freeze(Time.now) do
      Legion::LLM::Inventory.write_lane(lane: build_lane(provider: :vllm), ttl: 1)
      Timecop.travel(2) do
        described_class.sweep!
        expect(Legion::LLM::Inventory.lanes).to be_empty
      end
    end
  end

  it 'never drops lanes with expires_at: nil (static-catalog)' do
    Legion::LLM::Inventory.write_lane(lane: build_lane(provider: :anthropic, tier: :frontier, model: 'claude-sonnet-4-6'))
    described_class.sweep!
    expect(Legion::LLM::Inventory.lane(id: 'frontier:anthropic:default:inference:claude-sonnet-4-6')).not_to be_nil
  end

  it 'iterates via Inventory.expired_ids — never via .send(:map)' do
    src = File.read('lib/legion/llm/inventory/sweeper.rb')
    expect(src).not_to match(/Inventory\.send\(:map\)/)
    expect(src).to     match(/Inventory\.expired_ids/)
  end
end
