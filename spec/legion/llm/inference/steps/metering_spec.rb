# frozen_string_literal: true

require 'spec_helper'

RSpec.describe Legion::LLM::Pipeline::Steps::Metering do
  describe '.build_event' do
    it 'builds a metering event with all fields' do
      event = described_class.build_event(
        node_id: 'node-1', worker_id: 'w-1', agent_id: 'a-1',
        request_type: :chat, tier: :cloud, provider: :anthropic,
        model_id: 'claude-opus-4-6',
        input_tokens: 100, output_tokens: 50, thinking_tokens: 10,
        latency_ms: 250, wall_clock_ms: 300, routing_reason: 'intent-match'
      )
      expect(event[:node_id]).to eq('node-1')
      expect(event[:total_tokens]).to eq(160)
      expect(event[:latency_ms]).to eq(250)
      expect(event[:recorded_at]).to be_a(String)
    end

    it 'defaults tokens to zero' do
      event = described_class.build_event(model_id: 'test')
      expect(event[:input_tokens]).to eq(0)
      expect(event[:output_tokens]).to eq(0)
      expect(event[:thinking_tokens]).to eq(0)
      expect(event[:total_tokens]).to eq(0)
    end
  end

  describe '.publish_or_spool' do
    it 'returns :dropped when no transport or spool' do
      result = described_class.publish_or_spool({ model_id: 'test' })
      expect(result).to eq(:dropped)
    end
  end
end
