# frozen_string_literal: true

require 'spec_helper'

RSpec.describe Legion::LLM::Pipeline::GaiaCaller do
  describe '.chat' do
    it 'builds request with gaia caller profile' do
      executor = double('Executor')
      allow(executor).to receive(:call).and_return(
        Legion::LLM::Pipeline::Response.build(
          request_id: 'req_1', conversation_id: 'conv_1',
          message: { role: :assistant, content: 'summarized' }
        )
      )
      allow(Legion::LLM::Pipeline::Executor).to receive(:new) do |req|
        expect(req.caller[:requested_by][:type]).to eq(:system)
        expect(req.caller[:requested_by][:credential]).to eq(:internal)
        expect(Legion::LLM::Pipeline::Profile.derive(req.caller)).to eq(:gaia)
        executor
      end

      result = described_class.chat(
        message:       'summarize this',
        phase:         'knowledge_retrieval',
        tick_trace_id: 'trace_abc',
        tick_span_id:  'span_123'
      )

      expect(result).to be_a(Legion::LLM::Pipeline::Response)
      expect(result.message[:content]).to eq('summarized')
    end

    it 'includes tracing linkage to tick cycle' do
      executor = double('Executor')
      allow(executor).to receive(:call).and_return(
        Legion::LLM::Pipeline::Response.build(
          request_id: 'r', conversation_id: 'c',
          message: { role: :assistant, content: 'x' }
        )
      )
      allow(Legion::LLM::Pipeline::Executor).to receive(:new) do |req|
        expect(req.tracing[:parent_span_id]).to eq('span_123')
        expect(req.tracing[:correlation_id]).to start_with('gaia:tick:')
        executor
      end

      described_class.chat(
        message: 'test', phase: 'reflection',
        tick_trace_id: 'trace_abc', tick_span_id: 'span_123'
      )
    end

    it 'works without tick tracing args' do
      executor = double('Executor')
      allow(executor).to receive(:call).and_return(
        Legion::LLM::Pipeline::Response.build(
          request_id: 'r', conversation_id: 'c',
          message: { role: :assistant, content: 'ok' }
        )
      )
      allow(Legion::LLM::Pipeline::Executor).to receive(:new).and_return(executor)

      expect { described_class.chat(message: 'hello') }.not_to raise_error
    end
  end

  describe '.structured' do
    it 'builds request with response_format json_schema' do
      executor = double('Executor')
      allow(executor).to receive(:call).and_return(
        Legion::LLM::Pipeline::Response.build(
          request_id: 'r', conversation_id: 'c',
          message: { role: :assistant, content: '{"result": true}' }
        )
      )
      allow(Legion::LLM::Pipeline::Executor).to receive(:new) do |req|
        expect(req.response_format[:type]).to eq(:json_schema)
        executor
      end

      described_class.structured(message: 'analyze', schema: { type: :object })
    end
  end

  describe '.gaia_caller' do
    it 'returns caller hash with system type and internal credential' do
      caller_hash = described_class.gaia_caller('reflection')
      expect(caller_hash[:requested_by][:type]).to eq(:system)
      expect(caller_hash[:requested_by][:credential]).to eq(:internal)
      expect(caller_hash[:requested_by][:identity]).to include('gaia:tick:reflection')
    end
  end
end
