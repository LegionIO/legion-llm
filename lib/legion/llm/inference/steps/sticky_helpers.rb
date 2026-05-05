# frozen_string_literal: true

require 'legion/logging/helper'

module Legion
  module LLM
    module Inference
      module Steps
        module StickyHelpers
          include Legion::Logging::Helper

          private

          def sticky_enabled?
            sticky_setting(:enabled, true) != false
          end

          def trigger_sticky_turns
            sticky_setting(:trigger_turns, 2)
          end

          def execution_sticky_tool_calls
            sticky_setting(:execution_tool_calls, 5)
          end

          def max_history_entries
            sticky_setting(:max_history_entries, 50)
          end

          def max_result_length
            sticky_setting(:max_result_length, 2000)
          end

          def max_args_length
            sticky_setting(:max_args_length, 500)
          end

          def sticky_setting(key, default = nil)
            Legion::LLM::Settings.config_value(settings_value(:tool_sticky, default: {}), key, default)
          end

          def settings_value(*keys, default: nil)
            Legion::LLM::Settings.value(*keys, default: default)
          rescue StandardError => e
            handle_exception(e, level: :warn, handled: true, operation: 'llm.pipeline.steps.sticky.settings', keys: keys)
            default
          end
        end
      end
    end
  end
end
