# frozen_string_literal: true

require 'spec_helper'

RSpec.describe Legion::LLM::Inference::Executor do
  describe 'metering step registration' do
    it 'includes :metering in STEPS' do
      expect(described_class::STEPS).to include(:metering)
    end

    it 'includes :metering in POST_PROVIDER_STEPS' do
      expect(described_class::POST_PROVIDER_STEPS).to include(:metering)
    end

    it 'does not include :metering in PRE_PROVIDER_STEPS' do
      expect(described_class::PRE_PROVIDER_STEPS).not_to include(:metering)
    end
  end

  describe '#step_metering' do
    let(:request) do
      Legion::LLM::Inference::Request.build(
        messages:        [{ role: :user, content: 'hello' }],
        routing:         { provider: :anthropic, model: 'claude-opus-4-6' },
        conversation_id: 'conv_123',
        caller:          caller
      )
    end
    let(:caller) { { requested_by: { identity: 'user:alice', type: 'user', credential: 'cred_1' } } }

    subject(:executor) { described_class.new(request) }

    before do
      # Stub the raw_response with token data
      raw = double('raw_response',
                   content:       'hello',
                   input_tokens:  50,
                   output_tokens: 20)
      executor.instance_variable_set(:@raw_response, raw)
      executor.instance_variable_set(:@resolved_provider, :anthropic)
      executor.instance_variable_set(:@resolved_model, 'claude-opus-4-6')
      executor.instance_variable_set(:@timestamps,
                                     { provider_start: Time.now - 0.3,
                                       provider_end:   Time.now,
                                       received:       Time.now - 0.4 })
      executor.instance_variable_set(:@tracing, { correlation_id: 'corr_123' })
    end

    it 'calls Steps::Metering.build_event' do
      allow(Legion::LLM::Inference::Steps::Metering).to receive(:build_event).and_call_original
      allow(Legion::LLM::Inference::Steps::Metering).to receive(:publish_or_spool).and_return(:dropped)
      executor.send(:step_metering)
      expect(Legion::LLM::Inference::Steps::Metering).to have_received(:build_event)
    end

    it 'calls Steps::Metering.publish_or_spool with the built event' do
      allow(Legion::LLM::Inference::Steps::Metering).to receive(:publish_or_spool).and_return(:dropped)
      expect { executor.send(:step_metering) }.not_to raise_error
      expect(Legion::LLM::Inference::Steps::Metering).to have_received(:publish_or_spool)
    end

    it 'publishes cost, identity, conversation, and correlation metadata' do
      allow(Legion::LLM::Metering::Pricing).to receive(:estimate).and_return(0.00042)
      allow(Legion::LLM::Inference::Steps::Metering).to receive(:publish_or_spool)

      executor.send(:step_metering)

      expect(Legion::LLM::Inference::Steps::Metering).to have_received(:publish_or_spool) do |event|
        expect(event[:cost_usd]).to eq(0.00042)
        expect(event[:identity]).to eq(identity: 'user:alice', type: 'user', credential: 'cred_1')
        expect(event[:conversation_id]).to eq('conv_123')
        expect(event[:correlation_id]).to eq('corr_123')
        expect(event[:wall_clock_ms]).to be >= 0
      end
    end

    it 'estimates cost from canonical offering aliases when present' do
      executor.instance_variable_set(:@resolved_model, 'gpt4o-prod')
      executor.instance_variable_set(:@resolved_offering_metadata, { canonical_model_alias: 'gpt-4o' })
      allow(Legion::LLM::Metering::Pricing).to receive(:estimate).and_return(0.00042)
      allow(Legion::LLM::Inference::Steps::Metering).to receive(:publish_or_spool)

      executor.send(:step_metering)

      expect(Legion::LLM::Metering::Pricing).to have_received(:estimate).with(
        model_id:      'gpt-4o',
        input_tokens:  50,
        output_tokens: 20
      )
    end

    it 'does not emit a zero-dollar cost estimate when provider usage is missing for a known model' do
      logger = instance_double('Logger', debug: nil, warn: nil)
      raw = double('raw_response',
                   content:       'hello',
                   input_tokens:  nil,
                   output_tokens: nil)
      executor.instance_variable_set(:@raw_response, raw)
      allow(executor).to receive(:log).and_return(logger)
      allow(Legion::LLM::Metering::Pricing).to receive(:estimate)
      allow(Legion::LLM::Inference::Steps::Metering).to receive(:publish_or_spool)

      executor.send(:step_metering)

      expect(Legion::LLM::Metering::Pricing).not_to have_received(:estimate)
      expect(logger).to have_received(:warn).with(
        include('[llm][metering] zero_tokens', 'provider=anthropic', 'model=claude-opus-4-6')
      )
      expect(Legion::LLM::Inference::Steps::Metering).to have_received(:publish_or_spool) do |event|
        expect(event).not_to have_key(:cost_usd)
      end
    end

    context 'with agent metadata on the caller hash' do
      let(:caller) do
        {
          requested_by: { identity: 'fleet:worker-1', type: 'service' },
          agent:        { id: 'fleet:agent-1', task_id: 'task-123' }
        }
      end

      it 'publishes agent and task identifiers from caller metadata' do
        allow(Legion::LLM::Inference::Steps::Metering).to receive(:publish_or_spool)

        executor.send(:step_metering)

        expect(Legion::LLM::Inference::Steps::Metering).to have_received(:publish_or_spool) do |event|
          expect(event[:agent_id]).to eq('fleet:agent-1')
          expect(event[:task_id]).to eq('task-123')
        end
      end
    end

    context 'with a namespaced caller id and ambiguous display identity' do
      let(:caller) do
        {
          requested_by: {
            id:         'system:system',
            identity:   'system',
            type:       'service',
            credential: 'system'
          }
        }
      end

      it 'publishes the namespaced id as metering identity' do
        allow(Legion::LLM::Inference::Steps::Metering).to receive(:publish_or_spool)

        executor.send(:step_metering)

        expect(Legion::LLM::Inference::Steps::Metering).to have_received(:publish_or_spool) do |event|
          expect(event[:identity]).to eq(identity: 'system:system', type: 'service', credential: 'system')
        end
      end
    end

    context 'with a string caller' do
      let(:caller) { 'extension:lex-test' }

      it 'preserves the caller string as metering identity' do
        allow(Legion::LLM::Inference::Steps::Metering).to receive(:publish_or_spool)

        executor.send(:step_metering)

        expect(Legion::LLM::Inference::Steps::Metering).to have_received(:publish_or_spool) do |event|
          expect(event[:identity]).to eq(identity: 'extension:lex-test', type: 'extension')
        end
      end
    end

    it 'tolerates a nil raw_response without raising' do
      executor.instance_variable_set(:@raw_response, nil)
      expect { executor.send(:step_metering) }.not_to raise_error
    end
  end
end
