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
            sticky_setting(:enabled) != false
          end

          def trigger_sticky_turns
            sticky_setting(:trigger_turns)
          end

          def execution_sticky_tool_calls
            sticky_setting(:execution_tool_calls)
          end

          def max_history_entries
            sticky_setting(:max_history_entries)
          end

          def max_result_length
            sticky_setting(:max_result_length)
          end

          def max_args_length
            sticky_setting(:max_args_length)
          end

          def sticky_setting(key)
            Legion::Settings[:llm][:tools][:sticky][key]
          end
        end
      end
    end
  end
end
