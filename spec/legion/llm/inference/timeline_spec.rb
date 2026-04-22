# frozen_string_literal: true

require 'spec_helper'

RSpec.describe Legion::LLM::Inference::Timeline do
  subject(:timeline) { described_class.new }

  describe '#record' do
    it 'adds events with auto-incrementing seq' do
      timeline.record(category: :internal, key: 'tracing:init', detail: 'trace initialized')
      timeline.record(category: :audit, key: 'rbac:check', detail: 'permitted')
      events = timeline.events
      expect(events.length).to eq(2)
      expect(events[0][:seq]).to eq(1)
      expect(events[1][:seq]).to eq(2)
    end

    it 'includes exchange_id when provided' do
      timeline.record(
        category: :provider, key: 'provider:request_sent',
        exchange_id: 'exch_001', detail: 'POST to claude'
      )
      expect(timeline.events[0][:exchange_id]).to eq('exch_001')
    end

    it 'records timestamps' do
      timeline.record(category: :internal, key: 'test', detail: 'test')
      expect(timeline.events[0][:timestamp]).to be_a(Time)
    end
  end

  describe '#participants' do
    it 'collects unique from/to values in order' do
      timeline.record(category: :internal, key: 'a', detail: 'a', from: 'pipeline', to: 'rbac')
      timeline.record(category: :provider, key: 'b', detail: 'b', from: 'pipeline', to: 'provider:claude')
      timeline.record(category: :provider, key: 'c', detail: 'c', from: 'provider:claude', to: 'pipeline')
      expect(timeline.participants).to eq(%w[pipeline rbac provider:claude])
    end
  end
end
