# frozen_string_literal: true

require 'spec_helper'

# G28 / opus H2 — SettingsObserver ships in P1 commit 9
RSpec.describe Legion::LLM::Inventory::SettingsObserver do
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

  it 'handle_change re-writes lanes for the affected provider (G28)' do
    Legion::Settings.loader.settings[:extensions][:llm][:openai] ||= {}
    Legion::Settings.loader.settings[:llm][:routing][:tier_weights] = { frontier: 100 }
    Legion::Settings.loader.settings[:extensions][:llm][:openai][:weight] = 100
    Legion::LLM::Inventory.write_lane(lane: build_lane(provider: :openai, model: 'gpt-5.5'), ttl: 3600)
    initial_weight = Legion::LLM::Inventory.lane(id: 'frontier:openai:default:inference:gpt-5.5')[:lane_weight]

    Legion::Settings.loader.settings[:extensions][:llm][:openai][:weight] = 500
    described_class.handle_change(path: %i[extensions llm openai weight])

    reweighted = Legion::LLM::Inventory.lane(id: 'frontier:openai:default:inference:gpt-5.5')[:lane_weight]
    expect(reweighted).to be > initial_weight
  end

  it 'handle_change preserves circuit health on reweight (G21)' do
    Legion::Settings.loader.settings[:extensions][:llm][:openai] ||= {}
    Legion::Settings.loader.settings[:llm][:routing][:tier_weights] = { frontier: 100 }
    Legion::Settings.loader.settings[:extensions][:llm][:openai][:weight] = 100
    Legion::LLM::Inventory.write_lane(
      lane: build_lane(provider: :openai), ttl: 3600,
      health: { circuit_state: :open, denied: false, available: false, adjustment: -50 }
    )
    Legion::Settings.loader.settings[:extensions][:llm][:openai][:weight] = 500
    described_class.handle_change(path: %i[extensions llm openai weight])

    lane = Legion::LLM::Inventory.lane(id: 'frontier:openai:default:inference:gpt-5.5')
    expect(lane[:health][:circuit_state]).to eq(:open)
  end

  it 'rewrite_all_lanes! re-writes every lane' do
    Legion::Settings.loader.settings[:extensions][:llm][:openai] ||= {}
    Legion::Settings.loader.settings[:llm][:routing][:tier_weights] = { frontier: 100 }
    Legion::Settings.loader.settings[:extensions][:llm][:openai][:weight] = 100
    Legion::LLM::Inventory.write_lane(lane: build_lane(provider: :openai), ttl: 3600)
    initial = Legion::LLM::Inventory.lane(id: 'frontier:openai:default:inference:gpt-5.5')[:lane_weight]

    Legion::Settings.loader.settings[:extensions][:llm][:openai][:weight] = 300
    described_class.rewrite_all_lanes!

    updated = Legion::LLM::Inventory.lane(id: 'frontier:openai:default:inference:gpt-5.5')[:lane_weight]
    expect(updated).to be > initial
  end

  it 'attach! is callable and does not raise' do
    expect { described_class.attach! }.not_to raise_error
  end
end
