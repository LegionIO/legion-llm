# frozen_string_literal: true

require 'spec_helper'

RSpec.describe Legion::LLM::Pipeline::Profile do
  describe ':quick_reply profile' do
    let(:skipped_steps) do
      %i[
        idempotency conversation_uuid context_load classification
        gaia_advisory rag_context tool_discovery confidence_scoring
        tool_calls context_store post_response knowledge_capture
      ]
    end

    let(:kept_steps) do
      %i[
        tracing_init rbac billing routing request_normalization
        provider_call response_normalization response_return
      ]
    end

    it 'skips all 12 non-essential steps' do
      skipped_steps.each do |step|
        expect(described_class.skip?(:quick_reply, step)).to eq(true),
                                                             "expected :quick_reply to skip :#{step}"
      end
    end

    it 'keeps the 8 essential steps' do
      kept_steps.each do |step|
        expect(described_class.skip?(:quick_reply, step)).to eq(false),
                                                             "expected :quick_reply to keep :#{step}"
      end
    end
  end

  describe '.derive with :quick_reply activation' do
    it 'returns :quick_reply when requested_by type is :quick_reply' do
      caller = { requested_by: { identity: 'user:matt', type: :quick_reply, credential: :session } }
      expect(described_class.derive(caller)).to eq(:quick_reply)
    end

    it 'returns :quick_reply when requested_by type is the string "quick_reply"' do
      caller = { requested_by: { identity: 'user:matt', type: 'quick_reply', credential: :session } }
      expect(described_class.derive(caller)).to eq(:quick_reply)
    end
  end

  describe '.derive non-quick_reply type routing' do
    it 'returns :human for user callers' do
      caller = { requested_by: { identity: 'user:matt', type: :user, credential: :session } }
      expect(described_class.derive(caller)).to eq(:human)
    end

    it 'returns :gaia for gaia tick callers' do
      caller = { requested_by: { identity: 'gaia:tick', type: :system, credential: :internal } }
      expect(described_class.derive(caller)).to eq(:gaia)
    end

    it 'returns :system for system callers' do
      caller = { requested_by: { identity: 'system:healthcheck', type: :system, credential: :internal } }
      expect(described_class.derive(caller)).to eq(:system)
    end

    it 'returns :external for nil caller' do
      expect(described_class.derive(nil)).to eq(:external)
    end
  end
end
