# frozen_string_literal: true

require 'spec_helper'
require 'legion/llm/settings'

RSpec.describe Legion::LLM::Settings do
  describe '.default' do
    it 'enables GAIA advisory by default' do
      expect(described_class.default.dig(:gaia, :advisory_enabled)).to be true
    end

    it 'defaults client tool passthrough on with an empty whitelist and shell escalation blacklist' do
      expect(described_class.default.dig(:tools, :trigger, :client_tool_passthrough)).to be true
      expect(described_class.default.dig(:tools, :trigger, :client_tool_passthrough_whitelist)).to eq([])
      blacklist = described_class.default.dig(:tools, :trigger, :client_tool_passthrough_blacklist)
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
      expect(described_class.default.dig(:tools, :error_log_chars)).to eq(500)
    end

    it 'keeps all tool policy under the tools settings group' do
      expect(described_class.default[:tools]).to include(
        max_rounds:                200,
        max_calls_per_turn:        100,
        consecutive_failure_limit: 2,
        result_max_dispatch_chars: 5_000,
        python_venv_dir:           '~/.legionio/python'
      )
      expect(described_class.default.dig(:tools, :timeouts)).to eq(
        default:         1_000,
        max:             10_000,
        terminate_grace: 1_000
      )
      expect(described_class.default.dig(:tools, :confidence)).to include(
        override_threshold:           0.8,
        shadow_threshold:             0.5,
        success_delta:                0.05,
        failure_delta:                -0.1,
        apollo_limit:                 100,
        apollo_confidence_multiplier: 0.8,
        cache_ttl_seconds:            3_600
      )
    end

    it 'does not retain tool policy at the llm root' do
      expect(described_class.default).not_to include(
        :max_tool_rounds,
        :max_tool_calls_per_turn,
        :tool_error_log_chars,
        :tool_result_max_dispatch_chars,
        :tool_trigger
      )
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
