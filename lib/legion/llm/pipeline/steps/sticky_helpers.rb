# frozen_string_literal: true

module Legion
  module LLM
    module Pipeline
      module Steps
        module StickyHelpers
          private

          def sticky_enabled?
            Legion::Settings.dig(:llm, :tool_sticky, :enabled) != false
          end

          def trigger_sticky_turns
            Legion::Settings.dig(:llm, :tool_sticky, :trigger_turns) || 2
          end

          def execution_sticky_tool_calls
            Legion::Settings.dig(:llm, :tool_sticky, :execution_tool_calls) || 5
          end

          def max_history_entries
            Legion::Settings.dig(:llm, :tool_sticky, :max_history_entries) || 50
          end

          def max_result_length
            Legion::Settings.dig(:llm, :tool_sticky, :max_result_length) || 2000
          end

          def max_args_length
            Legion::Settings.dig(:llm, :tool_sticky, :max_args_length) || 500
          end
        end
      end
    end
  end
end
