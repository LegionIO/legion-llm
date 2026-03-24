# frozen_string_literal: true

require 'spec_helper'

RSpec.describe Legion::LLM::Pipeline::Profile do
  describe '.derive' do
    it 'returns :external for user callers' do
      caller = { requested_by: { identity: 'user:matt', type: :user, credential: :session } }
      expect(described_class.derive(caller)).to eq(:external)
    end

    it 'returns :external for mcp_client callers' do
      caller = { requested_by: { identity: 'mcp:claude_code', type: :mcp_client, credential: :jwt } }
      expect(described_class.derive(caller)).to eq(:external)
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

  describe '.skip?' do
    it 'returns false for external profile on any step' do
      expect(described_class.skip?(:external, :rbac)).to eq(false)
      expect(described_class.skip?(:external, :classification)).to eq(false)
    end

    it 'returns true for gaia profile on governance steps' do
      expect(described_class.skip?(:gaia, :rbac)).to eq(true)
      expect(described_class.skip?(:gaia, :classification)).to eq(true)
      expect(described_class.skip?(:gaia, :billing)).to eq(true)
      expect(described_class.skip?(:gaia, :gaia_advisory)).to eq(true)
      expect(described_class.skip?(:gaia, :post_response)).to eq(true)
    end

    it 'returns false for gaia profile on routing and provider steps' do
      expect(described_class.skip?(:gaia, :routing)).to eq(false)
      expect(described_class.skip?(:gaia, :provider_call)).to eq(false)
      expect(described_class.skip?(:gaia, :tracing)).to eq(false)
    end

    it 'skips most steps for system profile' do
      expect(described_class.skip?(:system, :rbac)).to eq(true)
      expect(described_class.skip?(:system, :context_load)).to eq(true)
      expect(described_class.skip?(:system, :rag_context)).to eq(true)
      expect(described_class.skip?(:system, :routing)).to eq(false)
      expect(described_class.skip?(:system, :provider_call)).to eq(false)
    end
  end
end
