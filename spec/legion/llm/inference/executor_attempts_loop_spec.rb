# frozen_string_literal: true

require 'spec_helper'

RSpec.describe Legion::LLM::Inference::Executor, 'attempts loop (P5)' do
  before { skip 'P5: executor stateless loop' }

  def seed_inventory_with(fixture)
    case fixture
    when :empty_for_filter
      # no lanes written — any provider filter will find nothing
    when :three_lanes_all_failing
      3.times do |i|
        Legion::LLM::Inventory.write_lane(lane: {
          id: "direct:vllm:instance#{i}:inference:gemma-12b",
          tier: :direct, provider_family: :vllm, instance_id: :"instance#{i}",
          model: 'gemma-12b', type: :inference
        })
      end
    when :five_lanes_all_failing
      5.times do |i|
        Legion::LLM::Inventory.write_lane(lane: {
          id: "direct:vllm:instance#{i}:inference:gemma-12b",
          tier: :direct, provider_family: :vllm, instance_id: :"instance#{i}",
          model: 'gemma-12b', type: :inference
        })
      end
    end
  end

  def dispatch_request(provider: nil, headers: {})
    raise NotImplementedError, 'implement dispatch_request fixture helper in P5'
  end

  it 'raises NoLaneAvailable on first request_lane nil' do
    seed_inventory_with(:empty_for_filter)
    expect { dispatch_request(provider: :nonexistent) }
      .to raise_error(Legion::LLM::Errors::NoLaneAvailable)
  end

  it 'raises EscalationExhausted after max_attempts dispatch failures' do
    seed_inventory_with(:three_lanes_all_failing)
    Legion::Settings.loader.settings[:llm][:routing][:max_attempts] = 3
    expect { dispatch_request }
      .to raise_error(Legion::LLM::Errors::EscalationExhausted) { |err|
        expect(err.attempts).to eq(3)
        expect(err.tried_lanes.size).to eq(3)
      }
  end

  it 'honors x-legion-max-attempts header override' do
    seed_inventory_with(:five_lanes_all_failing)
    expect { dispatch_request(headers: { 'x-legion-max-attempts' => '5' }) }
      .to raise_error(Legion::LLM::Errors::EscalationExhausted) { |err|
        expect(err.attempts).to eq(5)
      }
  end

  it 'uses bounded iteration (while remaining > 0), never loop do' do
    src = File.read('lib/legion/llm/inference/executor.rb')
    expect(src).not_to match(/^\s*loop do/)
  end
end
