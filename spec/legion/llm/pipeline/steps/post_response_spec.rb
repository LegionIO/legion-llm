# frozen_string_literal: true

require 'spec_helper'

RSpec.describe Legion::LLM::Pipeline::Steps::PostResponse do
  let(:klass) do
    Class.new do
      include Legion::LLM::Pipeline::Steps::PostResponse

      attr_accessor :request, :enrichments, :timeline, :warnings, :audit,
                    :raw_response, :tracing, :timestamps, :resolved_provider,
                    :resolved_model, :exchange_id

      def initialize(request)
        @request           = request
        @enrichments       = {}
        @timeline          = Legion::LLM::Pipeline::Timeline.new
        @warnings          = []
        @audit             = {}
        @tracing           = {}
        @timestamps        = { received: Time.now }
        @resolved_provider = :anthropic
        @resolved_model    = 'claude-opus-4-6'
        @exchange_id       = 'exch_001'
        @raw_response      = nil
      end
    end
  end

  let(:request) do
    Legion::LLM::Pipeline::Request.build(
      messages: [{ role: :user, content: 'hello' }],
      caller:   { requested_by: { identity: 'user:matt', type: :user } }
    )
  end

  describe '#step_post_response' do
    it 'calls AuditPublisher.publish' do
      step = klass.new(request)
      expect(Legion::LLM::Pipeline::AuditPublisher).to receive(:publish)
        .with(hash_including(request: request))
      step.step_post_response
    end

    it 'records timeline event' do
      step = klass.new(request)
      allow(Legion::LLM::Pipeline::AuditPublisher).to receive(:publish)
      step.step_post_response

      keys = step.timeline.events.map { |e| e[:key] }
      expect(keys).to include('audit:publish')
    end

    it 'does not raise when AuditPublisher raises' do
      step = klass.new(request)
      allow(Legion::LLM::Pipeline::AuditPublisher).to receive(:publish).and_raise(StandardError, 'oops')
      expect { step.step_post_response }.not_to raise_error
      expect(step.warnings).to include(match(/post_response error/))
    end
  end
end
