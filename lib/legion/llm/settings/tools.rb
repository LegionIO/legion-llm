# frozen_string_literal: true

module Legion
  module LLM
    module Settings
      module Tools
        extend Legion::Logging::Helper

        def self.defaults
          {
            max_rounds:                200,
            max_calls_per_turn:        100,
            consecutive_failure_limit: 2,
            explicit_choice_max_chars: 500,
            error_log_chars:           500,
            result_detail_chars:       100,
            result_max_dispatch_chars: 5_000,
            name_log_limit:            30,
            command_log_chars:         120,
            thinking_log_chars:        200,
            python_venv_dir:           '~/.legionio/python',
            timeouts:                  {
              default:         1_000,
              max:             10_000,
              terminate_grace: 1_000
            },
            trigger:                   {
              scan_depth:                        10,
              tool_limit:                        25,
              local_tool_limit:                  50,
              log_name_limit:                    20,
              client_tool_passthrough:           true,
              client_tool_passthrough_whitelist: [],
              client_tool_passthrough_blacklist: [
                'sudo', 'visudo', 'su', 'legion', 'legionio', 'legionio do', 'legionio/legion',
                'computer_use_session', 'computer_use_control', 'computer_use_session_info',
                'computer_use_session_message', 'plugin__aithena__recall', 'plugin__aithena__remember',
                'plugin__aithena__skill_search', 'plugin__aithena__skill_feedback', 'plugin__aithena__memory_stats',
                'plugin__cron__create', 'plugin__cron__list', 'plugin__cron__get', 'plugin__cron__update',
                'plugin__cron__delete', 'plugin__cron__get_history', 'plugin__cron__run_now', 'plugin__cron__stop'
              ]
            },
            history:                   {
              error_summary_chars:        100,
              large_json_threshold_chars: 2_000,
              summary_chars:              200,
              json_scan_chars:            500,
              json_key_limit:             3
            },
            context_compaction:        {
              threshold_chars: 500,
              result_chars:    200
            },
            sticky:                    {
              enabled:              true,
              trigger_turns:        2,
              execution_tool_calls: 5,
              max_history_entries:  50,
              max_result_length:    2_000,
              max_args_length:      500
            },
            confidence:                {
              override_threshold:           0.8,
              shadow_threshold:             0.5,
              success_delta:                0.05,
              failure_delta:                -0.1,
              apollo_limit:                 100,
              apollo_confidence_multiplier: 0.8,
              cache_ttl_seconds:            3_600
            }
          }
        end
      end
    end
  end
end
