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
    %i[published disabled dropped].each do |status|
      it "records the actual #{status} publication outcome without failing the request" do
        step = klass.new(request)
        allow(Legion::LLM::Inference::AuditPublisher).to receive(:publish).and_return(event: nil, status: status)

        step.step_post_response

        publication = step.timeline.events.find { |event| event[:key] == 'audit:publish' }
        expect(publication[:data]).to eq(status: status)
        expect(step.warnings).to be_empty
      end
    end

    it 'does not raise when AuditPublisher raises' do
      step = klass.new(request)
      allow(Legion::LLM::Inference::AuditPublisher).to receive(:publish).and_raise(StandardError, 'oops')
      expect { step.step_post_response }.not_to raise_error
      expect(step.warnings).to include(match(/post_response error/))
    end

    context 'when Legion::Gaia::AuditObserver is defined' do
      before do
        stub_const('Legion::Gaia::AuditObserver', Class.new do
          def self.instance
            @instance ||= new
          end

          def process_event(_event); end
        end)
      end

      %i[disabled dropped].each do |status|
        it "observes the built event locally even when transport is #{status}" do
          audit_event = { caller: { requested_by: { identity: 'user:matt' } }, response_content: 'answer' }
          allow(Legion::LLM::Inference::AuditPublisher).to receive(:publish).and_return(event: audit_event, status: status)
          observer = Legion::Gaia::AuditObserver.instance
          expect(observer).to receive(:process_event).with(audit_event)
          step = klass.new(request)

          step.step_post_response

          expect(step.timeline.events.last[:data]).to eq(status: status)
          expect(step.warnings).to be_empty
        end
      end
    end

    context 'when Legion::Gaia::AuditObserver is not defined' do
      it 'skips AuditObserver gracefully' do
        allow(Legion::LLM::Inference::AuditPublisher).to receive(:publish).and_return(event: { timestamp: Time.now }, status: :published)
        step = klass.new(request)
        step.step_post_response
        expect(step.warnings).to be_empty
        expect(step.timeline.events.last[:data]).to eq(status: :published)
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
