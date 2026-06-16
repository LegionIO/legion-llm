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

    it 'defaults tool error log summaries to 500 characters' do
      expect(described_class.default[:tool_error_log_chars]).to eq(500)
    end
  end

  describe '.register_defaults!' do
    it 'registers defaults into Legion::Settings[:llm]' do
      described_class.register_defaults!
      expect(Legion::Settings[:llm][:enabled]).to eq(true)
      expect(Legion::Settings[:llm][:routing][:enabled]).to eq(true)
    end
  end

  describe '.validate!' do
    it 'raises on removed gateway key' do
      expect { described_class.validate!(gateway: {}) }.to raise_error(ArgumentError, /gateway/)
    end

    it 'raises on removed routing.use_fleet key' do
      expect { described_class.validate!(routing: { use_fleet: true }) }.to raise_error(ArgumentError, /use_fleet/)
    end
  end
end
