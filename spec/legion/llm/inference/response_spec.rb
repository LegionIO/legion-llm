# frozen_string_literal: true

require 'spec_helper'

RSpec.describe Legion::LLM::Inference::Response do
  describe '.build' do
    it 'creates a response with defaults' do
      resp = described_class.build(
        request_id:      'req_abc',
        conversation_id: 'conv_xyz',
        message:         { role: :assistant, content: 'hi' }
      )
      expect(resp.id).to start_with('resp_')
      expect(resp.request_id).to eq('req_abc')
      expect(resp.schema_version).to eq('1.0.0')
      expect(resp.message[:content]).to eq('hi')
      expect(resp.enrichments).to eq({})
      expect(resp.audit).to eq({})
      expect(resp.timeline).to eq([])
      expect(resp.participants).to eq([])
      expect(resp.frozen?).to eq(true)
    end
  end

  # G3: the legacy .from_provider_message constructor is gone — the envelope
  # is built by the executor's build_response from the canonical provider
  # response (that legacy path fabricated :end_turn for an absent stop).

  describe '#with' do
    it 'returns a new response with updated fields' do
      resp = described_class.build(
        request_id:      'req_abc',
        conversation_id: 'conv_xyz',
        message:         { role: :assistant, content: 'hi' }
      )
      updated = resp.with(warnings: ['test warning'])
      expect(updated.warnings).to eq(['test warning'])
      expect(resp.warnings).to eq([])
    end
  end
end
