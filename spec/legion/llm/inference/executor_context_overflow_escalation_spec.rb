# frozen_string_literal: true

require 'spec_helper'

RSpec.describe Legion::LLM::Inference::Executor, 'context overflow escalation' do
  let(:request) do
    Legion::LLM::Inference::Request.build(
      messages: [{ role: :user, content: 'hello' }],
      routing:  { provider: :vllm, model: 'gemma-4-31b-it' }
    )
  end
  let(:executor) { described_class.new(request) }

  before do
    allow(Legion::LLM::Router).to receive(:routing_enabled?).and_return(true)
    allow(Legion::LLM::Audit).to receive(:emit_prompt)
    allow(executor).to receive(:emit_escalation_attempt_metering)
    allow(executor).to receive(:emit_escalation_attempt_audit)
  end

  describe '#classify_and_accumulate_exclusions with context_overflow' do
    let(:lane) do
      {
        id:              'direct:vllm:h200:inference:gemma-4-31b-it',
        provider_family: :vllm,
        instance_id:     :h200,
        model:           'gemma-4-31b-it',
        lane_weight:     100_000_000,
        limits:          { context_window: 262_144 }
      }
    end
    let(:payload) { { tried_lanes: [], models: ['gemma-4-31b-it'] } }

    context 'when a lane with a larger context window exists' do
      before do
        # Simulate a bedrock lane with 200k context being available
        allow(Legion::LLM::Inventory).to receive(:lanes).and_return([
                                                                      lane,
                                                                      {
                                                                        id:              'cloud:bedrock:primary:inference:claude-sonnet-4-6',
                                                                        provider_family: :bedrock,
                                                                        instance_id:     :primary,
                                                                        model:           'claude-sonnet-4-6',
                                                                        lane_weight:     50_000_000,
                                                                        limits:          { context_window: 1_048_576 }
                                                                      }
                                                                    ])
      end

      it 'does not raise terminal — adds the lane to tried_lanes for retry' do
        error = Legion::LLM::ContextOverflow.new(
          "vllm:gemma-4-31b-it — This model's maximum context length is 262144 tokens. " \
          'However, you requested 0 output tokens and your prompt contains at least 262145 input tokens'
        )

        # Should NOT raise — should push to tried_lanes so the loop can try a bigger model
        expect do
          executor.send(:classify_and_accumulate_exclusions, error: error, lane: lane, payload: payload)
        end.not_to raise_error

        expect(payload[:tried_lanes]).to include(lane[:id])
      end
    end

    context 'when no lane with a larger context window exists' do
      before do
        # Only the same model available — nowhere to escalate
        allow(Legion::LLM::Inventory).to receive(:lanes).and_return([lane])
      end

      it 'raises terminal since no larger context is available' do
        error = Legion::LLM::ContextOverflow.new(
          "vllm:gemma-4-31b-it — This model's maximum context length is 262144 tokens."
        )

        expect do
          executor.send(:classify_and_accumulate_exclusions, error: error, lane: lane, payload: payload)
        end.to raise_error(Legion::LLM::ContextOverflow)
      end
    end
  end
end
