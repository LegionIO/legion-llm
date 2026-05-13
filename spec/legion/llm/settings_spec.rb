# frozen_string_literal: true

require 'spec_helper'
require 'legion/llm/settings'

RSpec.describe Legion::LLM::Settings do
  describe '.default' do
    it 'enables GAIA advisory by default' do
      expect(described_class.default.dig(:gaia, :advisory_enabled)).to be true
    end
  end

  describe '.value' do
    it 'warns when a configured path traverses a scalar value' do
      Legion::Settings[:llm][:routing] = 'invalid'

      expect(described_class.log).to receive(:warn).with(/invalid_path.*routing.enabled/)

      expect(described_class.value(:routing, :enabled, default: false)).to be false
    end
  end

  describe '.global_value' do
    it 'warns when a global path traverses a scalar value' do
      Legion::Settings.merge_settings('mcp', { overrides: 'invalid' })
      allow(Legion::Settings).to receive(:dig).and_return(nil)

      expect(described_class.log).to receive(:warn).with(/invalid_path.*mcp.overrides.tool/)

      expect(described_class.global_value(:mcp, :overrides, :tool, default: nil)).to be_nil
    end
  end
end
