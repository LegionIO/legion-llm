# frozen_string_literal: true

require 'spec_helper'

RSpec.describe Legion::LLM::Inference::Steps::PostResponse do
  let(:klass) do
    Class.new do
      include Legion::LLM::Inference::Steps::PostResponse

      attr_accessor :request, :enrichments, :timeline, :warnings, :audit,
                    :raw_response, :tracing, :timestamps, :resolved_provider,
                    :resolved_model, :exchange_id

      def initialize(request)
        @request           = request
        @enrichments       = {}
        @timeline          = Legion::LLM::Inference::Timeline.new
        @warnings          = []
        @audit             = {}
        @tracing           = {}
        @timestamps        = { received: Time.now }
        @resolved_provider = :anthropic
        @resolved_model    = 'claude-opus-4-6'
        @exchange_id       = 'exch_001'
        @raw_response      = nil
      end

      private

      def build_response
        Legion::LLM::Inference::Response.build(
          request_id:      @request.id,
          conversation_id: @request.conversation_id || 'conv_test',
          message:         { role: :assistant, content: 'ok' },
          routing:         { provider: @resolved_provider, model: @resolved_model },
          tokens:          { input_tokens: 0, output_tokens: 0, total: 0 },
          stop:            { reason: :end_turn },
          stream:          false,
          timestamps:      @timestamps,
          enrichments:     @enrichments,
          audit:           @audit,
          timeline:        @timeline.events,
          tracing:         @tracing,
          caller:          @request.caller
        )
      end
    end
  end

  let(:request) do
    Legion::LLM::Inference::Request.build(
      messages: [{ role: :user, content: 'hello' }],
      caller:   { requested_by: { identity: 'user:matt', type: :user } }
    )
  end

  describe '#step_post_response' do
    it 'calls AuditPublisher.publish' do
      step = klass.new(request)
      expect(Legion::LLM::Inference::AuditPublisher).to receive(:publish)
        .with(hash_including(request: request))
      step.step_post_response
    end

    it 'records timeline event' do
      step = klass.new(request)
      allow(Legion::LLM::Inference::AuditPublisher).to receive(:publish)
      step.step_post_response

      keys = step.timeline.events.map { |e| e[:key] }
      expect(keys).to include('audit:publish')
    end

    it 'does not raise when AuditPublisher raises' do
      step = klass.new(request)
      allow(Legion::LLM::Inference::AuditPublisher).to receive(:publish).and_raise(StandardError, 'oops')
      expect { step.step_post_response }.not_to raise_error
      expect(step.warnings).to include(match(/post_response error/))
    end

    context 'when Legion::Gaia::AuditObserver is defined' do
      let(:fake_observer) { instance_double('FakeObserver') }

      before do
        stub_const('Legion::Gaia::AuditObserver', Class.new do
          def self.instance
            @instance ||= new
          end

          def process_event(_event); end
        end)
      end

      it 'calls AuditObserver.instance.process_event with the audit event' do
        audit_event = { caller: { requested_by: { identity: 'user:matt' } }, routing: { provider: :anthropic, model: 'claude-sonnet-4-6' },
timestamp: Time.now }
        allow(Legion::LLM::Inference::AuditPublisher).to receive(:publish).and_return(audit_event)
        observer = Legion::Gaia::AuditObserver.instance
        expect(observer).to receive(:process_event).with(audit_event)
        step = klass.new(request)
        step.step_post_response
      end
    end

    context 'when Legion::Gaia::AuditObserver is not defined' do
      it 'skips AuditObserver gracefully' do
        allow(Legion::LLM::Inference::AuditPublisher).to receive(:publish).and_return({ timestamp: Time.now })
        step = klass.new(request)
        expect { step.step_post_response }.not_to raise_error
      end
    end
  end

  describe '#extract_tokens' do
    it 'warns when provider usage fields collapse to zero tokens for a known model' do
      logger = instance_double('Logger', debug: nil, warn: nil)
      response = Struct.new(:input_tokens, :output_tokens).new(nil, nil)
      step = klass.new(request)
      step.raw_response = response
      allow(step).to receive(:log).and_return(logger)

      usage = step.send(:extract_tokens)

      expect(usage.input_tokens).to eq(0)
      expect(usage.output_tokens).to eq(0)
      expect(logger).to have_received(:warn).with(
        include('[llm][post_response] zero_tokens', 'provider=anthropic', 'model=claude-opus-4-6')
      )
    end
  end
end
