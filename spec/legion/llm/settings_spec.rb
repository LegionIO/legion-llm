# frozen_string_literal: true

require 'spec_helper'
require 'legion/llm/settings'

RSpec.describe Legion::LLM::Settings do
  describe '.default' do
    it 'enables GAIA advisory by default' do
      expect(described_class.default.dig(:gaia, :advisory_enabled)).to be true
    end

    it 'defaults client tool passthrough on with an empty whitelist and shell escalation blacklist' do
      expect(described_class.default.dig(:tool_trigger, :client_tool_passthrough)).to be true
      expect(described_class.default.dig(:tool_trigger, :client_tool_passthrough_whitelist)).to eq([])
      blacklist = described_class.default.dig(:tool_trigger, :client_tool_passthrough_blacklist)
      expect(blacklist).to include(
        'sudo', 'visudo', 'su', 'legion', 'legionio', 'legionio do', 'legionio/legion',
        'computer_use_session', 'computer_use_control', 'computer_use_session_info',
        'computer_use_session_message', 'plugin__aithena__recall', 'plugin__aithena__remember',
        'plugin__aithena__skill_search', 'plugin__aithena__skill_feedback', 'plugin__aithena__memory_stats',
        'plugin__cron__create', 'plugin__cron__list', 'plugin__cron__get', 'plugin__cron__update',
        'plugin__cron__delete', 'plugin__cron__get_history', 'plugin__cron__run_now', 'plugin__cron__stop'
      )
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
