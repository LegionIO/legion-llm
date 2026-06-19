# frozen_string_literal: true

require 'spec_helper'

RSpec.describe 'Compliance by absence (P3)' do
  before { skip 'P3: write-time policy enforcement' }

  def build_lane(provider: :bedrock, model: 'claude-sonnet-4-6', tier: :cloud)
    {
      id:              "#{tier}:#{provider}:default:inference:#{model}",
      tier:            tier,
      provider_family: provider,
      instance_id:     :default,
      model:           model,
      type:            :inference
    }
  end

  it 'blacklisted model never enters Inventory regardless of writer source' do
    Legion::Settings.loader.settings[:extensions][:llm][:bedrock][:model_blacklist] = ['claude-old']
    Legion::LLM::Inventory.write_lane(lane: build_lane(provider: :bedrock, model: 'claude-old'))
    expect(Legion::LLM::Inventory.lane(id: 'cloud:bedrock:default:inference:claude-old')).to be_nil
  end

  it 'whitelisted-only mode rejects everything not on the list' do
    Legion::Settings.loader.settings[:extensions][:llm][:bedrock][:model_whitelist] = ['claude-sonnet-4-6']
    Legion::LLM::Inventory.write_lane(lane: build_lane(provider: :bedrock, model: 'claude-sonnet-4-6'))
    Legion::LLM::Inventory.write_lane(lane: build_lane(provider: :bedrock, model: 'claude-old'))
    expect(Legion::LLM::Inventory.lanes_for(provider: :bedrock).map { _1[:model] }).to eq(['claude-sonnet-4-6'])
  end
end
