# frozen_string_literal: true

require 'legion/logging/helper'
require_relative 'logging'

module Legion
  module LLM
    module Inference
      module Steps
        module ToolHistory
          include Legion::Logging::Helper
          include Steps::Logging
          include Steps::StickyHelpers

          def step_tool_history_inject
            unless sticky_enabled?
              log_step_debug(:tool_history, :skipped, reason: :sticky_disabled)
              return
            end
            unless @request.conversation_id
              log_step_debug(:tool_history, :skipped, reason: :no_conversation_id)
              return
            end

            state   = Inference::Conversation.read_sticky_state(@request.conversation_id)
            history = state[:tool_call_history] || []
            if history.empty?
              log_step_debug(:tool_history, :skipped, reason: :empty_history)
              return
            end

            @enrichments['tool:call_history'] = {
              content:   format_history(history),
              data:      { entry_count: history.size },
              timestamp: Time.now
            }
            log_step_debug(:tool_history, :injected, history_count: history.size)
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

            str = result_str.to_s
            # If result is JSON but too long/truncated, avoid trying to parse incomplete JSON.
            # Large tool results (e.g. legion_list_special_tools) can be 2KB+ and get
            # truncated, causing parse errors that add noise to the logs.
            if str.length > 2000 && str.start_with?('{')
              # Return a summary for large JSON results without parsing
              keys = extract_json_top_keys(str)
              return keys.empty? ? "large JSON result (#{str.length} chars)" : "JSON with keys: #{keys.join(', ')}"
            end

            begin
              parsed = Legion::JSON.load(str)
            rescue StandardError
              return str[0, 200]
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
                str[0, 200]
              end
            else
              str[0, 200]
            end
          end

          def extract_json_top_keys(str)
            return [] unless str.start_with?('{')

            keys = []
            in_key = false
            buffer = +''
            brace_depth = 0
            bracket_depth = 0
            in_string = false
            escaped = false
            char_limit = [str.length, 500].min # Only scan first 500 chars

            (0...char_limit).each do |i|
              ch = str[i]
              if escaped
                escaped = false
                next
              end
              if ch == '\\' && in_string
                escaped = true
                buffer << ch
                next
              end
              in_string = !in_string if ch == '"' && !escaped
              next unless in_string

              if brace_depth == 1 && buffer.empty? && ch != '"'
                in_key = true
              elsif in_key && ch == '"'
                in_key = false
                keys << buffer unless buffer.empty?
                buffer = +''
                break if keys.size >= 3 # Only need first 3 keys
              else
                buffer << ch
              end
              next if in_string

              brace_depth += 1 if ch == '{'
              brace_depth -= 1 if ch == '}'
              bracket_depth += 1 if ch == '['
              bracket_depth -= 1 if ch == ']'
            end

            keys
          end
        end
      end
    end
  end
end
