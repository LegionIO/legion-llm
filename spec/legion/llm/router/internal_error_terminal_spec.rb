# frozen_string_literal: true

require 'spec_helper'

# G25 / h200 C1 / PR #152 C5/C6 — pending P5 commit 1
RSpec.describe 'Internal error is terminal — no retry (P5)' do
  before { skip 'P5: executor stateless loop' }

  def seed_inventory_with(fixture)
    case fixture
    when :two_lanes
      [[:a, :vllm], [:b, :vllm]].each do |inst, provider|
        Legion::LLM::Inventory.write_lane(lane: {
          id: "direct:#{provider}:#{inst}:inference:gemma-12b",
          tier: :direct, provider_family: provider, instance_id: inst,
          model: 'gemma-12b', type: :inference
        })
      end
    end
  end

  def dispatch_request_with_first_lane_raising(error)
    raise NotImplementedError, 'implement dispatch fixture in P5'
  end

  def routing_payload
    raise NotImplementedError, 'implement routing_payload accessor in P5'
  end

  it 'internal_error (NoMethodError) is terminal — does NOT retry on a different lane' do
    seed_inventory_with(:two_lanes)
    expect(Legion::LLM::Router.health_tracker).not_to receive(:report)
    expect { dispatch_request_with_first_lane_raising(NoMethodError.new('typo in shared code')) }
      .to raise_error(NoMethodError)
    expect(routing_payload[:tried_lanes].size).to be <= 1
  end
end
