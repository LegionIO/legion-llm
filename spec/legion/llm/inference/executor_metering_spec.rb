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

    context 'with a string caller' do
      let(:caller) { 'extension:lex-test' }

      it 'preserves the caller string as metering identity' do
        allow(Legion::LLM::Inference::Steps::Metering).to receive(:publish_or_spool)

        executor.send(:step_metering)

        expect(Legion::LLM::Inference::Steps::Metering).to have_received(:publish_or_spool) do |event|
          expect(event[:identity]).to eq(identity: 'extension:lex-test')
        end
      end
    end

    it 'tolerates a nil raw_response without raising' do
      executor.instance_variable_set(:@raw_response, nil)
      expect { executor.send(:step_metering) }.not_to raise_error
    end
  end
end
