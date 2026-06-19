# frozen_string_literal: true

require 'spec_helper'

# G28 / opus H2 — pending P2
RSpec.describe Legion::LLM::Inventory, 'settings observer re-weights lanes immediately (P2)' do
  before { skip 'P2: settings observer reweight' }

  def build_lane(provider: :openai, model: 'gpt-5.5', tier: :frontier)
    {
      id:              "#{tier}:#{provider}:default:inference:#{model}",
      tier:            tier,
      provider_family: provider,
      instance_id:     :default,
      model:           model,
      type:            :inference
    }
  end

  it 'settings observer re-writes affected lanes immediately on weight change' do
    Legion::LLM::Inventory.write_lane(lane: build_lane(provider: :openai, model: 'gpt-5.5'), ttl: 3600)
    initial_weight = Legion::LLM::Inventory.lane(id: 'frontier:openai:default:inference:gpt-5.5')[:lane_weight]

    Legion::Settings.loader.settings[:extensions][:llm][:openai][:weight] = 500
    Legion::Settings.observers.fire(:extensions, :llm, :openai, :weight)

    reweighted = Legion::LLM::Inventory.lane(id: 'frontier:openai:default:inference:gpt-5.5')[:lane_weight]
    expect(reweighted).to be > initial_weight
    expect(reweighted / initial_weight.to_f).to be_within(0.01).of(5.0)
  end
end
