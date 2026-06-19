# frozen_string_literal: true

require 'spec_helper'

# G22 / opus C2 — pending P1 commit 5
RSpec.describe Legion::LLM::Inventory, 'lane id format validation (P1)' do
  def build_lane(**overrides)
    {
      id:              'direct:vllm:default:inference:gemma-12b',
      tier:            :direct,
      provider_family: :vllm,
      instance_id:     :default,
      model:           'gemma-12b',
      type:            :inference
    }.merge(overrides)
  end

  it 'rejects writes with malformed (non-5-part) :id' do
    expect do
      Legion::LLM::Inventory.write_lane(lane: build_lane(id: 'vllm:apollo:gemma-12b'))
    end.to raise_error(Legion::LLM::Errors::InvalidLane, /5-part id/)
  end

  it 'rejects writes missing :id' do
    expect do
      Legion::LLM::Inventory.write_lane(lane: build_lane(id: nil))
    end.to raise_error(Legion::LLM::Errors::InvalidLane, /:id required/)
  end
end
