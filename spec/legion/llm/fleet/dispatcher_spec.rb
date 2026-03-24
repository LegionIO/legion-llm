# frozen_string_literal: true

require 'spec_helper'

RSpec.describe Legion::LLM::Fleet::Dispatcher do
  describe '.fleet_available?' do
    it 'returns false when transport is not connected' do
      expect(described_class.fleet_available?).to eq(false)
    end
  end

  describe '.fleet_enabled?' do
    it 'returns true by default' do
      expect(described_class.fleet_enabled?).to eq(true)
    end

    it 'returns false when use_fleet is false' do
      Legion::Settings[:llm][:routing] = { use_fleet: false }
      expect(described_class.fleet_enabled?).to eq(false)
    end
  end

  describe '.dispatch' do
    it 'returns fleet_unavailable when fleet is not available' do
      result = described_class.dispatch(model: 'test', messages: [])
      expect(result[:success]).to eq(false)
      expect(result[:error]).to eq('fleet_unavailable')
    end
  end

  describe '.resolve_timeout' do
    it 'returns default timeout when no override' do
      expect(described_class.resolve_timeout(nil)).to eq(30)
    end

    it 'returns override when provided' do
      expect(described_class.resolve_timeout(60)).to eq(60)
    end

    it 'reads from settings' do
      Legion::Settings[:llm][:routing] = { fleet: { timeout_seconds: 45 } }
      expect(described_class.resolve_timeout(nil)).to eq(45)
    end
  end
end
