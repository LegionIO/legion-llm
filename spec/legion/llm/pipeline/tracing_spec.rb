# frozen_string_literal: true

require 'spec_helper'

RSpec.describe Legion::LLM::Pipeline::Tracing do
  describe '.init' do
    it 'generates tracing hash with trace_id and span_id' do
      result = described_class.init
      expect(result[:trace_id]).to be_a(String)
      expect(result[:trace_id].length).to eq(32)
      expect(result[:span_id]).to be_a(String)
      expect(result[:span_id].length).to eq(16)
      expect(result[:parent_span_id]).to be_nil
    end

    it 'preserves existing trace_id from request' do
      existing = { trace_id: 'abc123', span_id: 'def456', parent_span_id: nil }
      result = described_class.init(existing: existing)
      expect(result[:trace_id]).to eq('abc123')
      expect(result[:span_id]).not_to eq('def456')
      expect(result[:parent_span_id]).to eq('def456')
    end
  end

  describe '.exchange_id' do
    it 'generates a unique exchange ID' do
      id = described_class.exchange_id
      expect(id).to start_with('exch_')
      expect(id.length).to be > 10
    end

    it 'generates unique IDs each call' do
      ids = Array.new(10) { described_class.exchange_id }
      expect(ids.uniq.length).to eq(10)
    end
  end
end
