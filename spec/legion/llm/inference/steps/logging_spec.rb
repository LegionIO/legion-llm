# frozen_string_literal: true

require 'spec_helper'

RSpec.describe Legion::LLM::Inference::Steps::Logging do
  let(:logger) { instance_double('Logger', debug: nil, info: nil) }
  let(:request) do
    Legion::LLM::Inference::Request.build(
      id:              'req_step_log',
      conversation_id: 'conv_step_log',
      messages:        []
    )
  end

  let(:step) do
    Class.new do
      include Legion::LLM::Inference::Steps::Logging

      attr_reader :request

      def initialize(request)
        @request = request
      end
    end.new(request)
  end

  before do
    allow(step).to receive(:log).and_return(logger)
  end

  it 'logs step actions with request and conversation context' do
    step.send(:log_step_debug, :classification, :scan_complete, pattern_count: 2, flags: %i[pii phi])

    expect(logger).to have_received(:debug).with(
      include(
        '[llm][steps][classification] action=scan_complete',
        'request_id=req_step_log',
        'conversation_id=conv_step_log',
        'pattern_count=2',
        'flags=count=2'
      )
    )
  end

  it 'summarizes hash context instead of dumping payloads' do
    step.send(:log_step_info, :post_response, :publish_audit, payload: { content: 'hidden' })

    expect(logger).to have_received(:info).with(
      include(
        '[llm][steps][post_response] action=publish_audit',
        'payload=keys=1'
      )
    )
  end
end
