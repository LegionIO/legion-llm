# frozen_string_literal: true

require 'legion/logging/helper'

module Legion
  module LLM
    module Inference
      module Steps
        module ToolHistory
          include Legion::Logging::Helper
          include Steps::StickyHelpers

          def step_tool_history_inject
            return unless sticky_enabled? && @request.conversation_id

            state   = Inference::Conversation.read_sticky_state(@request.conversation_id)
            history = state[:tool_call_history] || []
            return if history.empty?

            @enrichments['tool:call_history'] = {
              content:   format_history(history),
              data:      { entry_count: history.size },
              timestamp: Time.now
            }
          rescue StandardError => e
            @warnings << "tool_history_inject error: #{e.message}"
            handle_exception(e, level: :warn, operation: 'llm.pipeline.step_tool_history_inject')
          end

          private

          def format_history(history)
            lines = history.map { |entry| format_history_entry(entry) }
            "Tools used in this conversation:\n#{lines.join("\n")}"
          end

          def format_history_entry(entry)
            args_str = (entry[:args] || {}).map do |k, v|
              val = v.is_a?(String) ? v : Legion::JSON.dump(v)
              "#{k}: #{val}"
            end.join(', ')
            summary = summarize_result(entry[:result], entry[:error])
            "- Turn #{entry[:turn]}: #{entry[:tool]}(#{args_str}) \u2192 #{summary}"
          end

          def summarize_result(result_str, error)
            return "error: #{result_str.to_s[0, 100]}" if error

            begin
              parsed = Legion::JSON.load(result_str.to_s)
            rescue StandardError
              return result_str.to_s[0, 200]
            end

            if parsed.is_a?(Array)
              "#{parsed.size} items returned"
            elsif parsed.is_a?(Hash)
              if parsed[:number] && parsed[:html_url]
                "##{parsed[:number]} at #{parsed[:html_url]}"
              elsif parsed[:result].is_a?(Array)
                "#{parsed[:result].size} items returned"
              elsif parsed[:result].is_a?(Hash) && parsed[:result][:number]
                "##{parsed[:result][:number]} at #{parsed[:result][:html_url]}"
              else
                result_str.to_s[0, 200]
              end
            else
              result_str.to_s[0, 200]
            end
          end
        end
      end
    end
  end
end
