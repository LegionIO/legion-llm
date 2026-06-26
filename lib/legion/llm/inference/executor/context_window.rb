# frozen_string_literal: true

module Legion
  module LLM
    module Inference
      class Executor
        # ContextWindow methods extracted from Executor verbatim (P4b §1.5, refactor-under-green).
        # Functional message-list transformations: empty/thinking/tool-result trimming and
        # context-window-aware compaction. Operates on the messages argument; reads
        # @request.id for log lines and @resolved_offering_metadata via resolved_context_window.
        module ContextWindow
          def native_dispatch_messages
            messages = apply_conversation_breakpoint(@request.messages)
            rejected = messages.count { |m| empty_assistant_message?(m) }
            if rejected.positive?
              log.warn "[llm][executor] action=strip_empty_assistants request_id=#{@request.id} removed=#{rejected}"
              messages = messages.reject { |m| empty_assistant_message?(m) }
            end
            messages = strip_thinking_from_history(messages)
            messages = trim_oversized_tool_results(messages)
            enforce_context_window(messages)
          end

          def enforce_context_window(messages)
            context_window = resolved_context_window
            @context_accounting[:component_status][:context_window] = :observed
            return messages unless context_window&.positive?

            threshold = (context_window * Legion::Settings[:llm][:context_curation][:context_window_threshold]).to_i
            tool_budget = estimate_tool_token_budget
            available_for_messages = threshold - tool_budget
            estimated = estimate_message_tokens(messages)
            return messages if estimated <= available_for_messages

            log.warn "[llm][executor] action=context_compaction request_id=#{@request.id} " \
                     "estimated_tokens=#{estimated} context_window=#{context_window} " \
                     "threshold=#{threshold} tool_budget=#{tool_budget} available=#{available_for_messages}"

            preserve_after = last_user_message_index(messages)
            recent = messages[preserve_after..]
            older = messages[0...preserve_after]

            target_tokens = available_for_messages - estimate_message_tokens(recent)
            compacted = compact_to_fit(older, target_tokens)

            result = compacted + recent
            after_tokens = estimate_message_tokens(result)
            saved = [estimated - after_tokens, 0].max

            @context_accounting[:tokens][:context_window_saved_estimated_tokens] += saved
            @context_accounting[:counts][:context_window_message_count_before] = messages.size
            @context_accounting[:counts][:context_window_message_count_after] = result.size
            @context_accounting[:events] << ContextAccounting.event(
              event_type:    :context_window_enforcement,
              component:     :context_window,
              before_tokens: estimated,
              after_tokens:  after_tokens,
              before_count:  messages.size,
              after_count:   result.size,
              metadata:      { context_window: context_window, threshold: threshold }
            )

            log.info "[llm][executor] action=context_compaction_complete request_id=#{@request.id} " \
                     "before=#{messages.size} after=#{result.size} " \
                     "tokens_before=#{estimated} tokens_after=#{after_tokens}"
            result
          end

          def compact_to_fit(messages, target_tokens)
            return messages if estimate_message_tokens(messages) <= target_tokens

            filtered = messages.reject do |msg|
              role = (msg[:role] || msg['role']).to_s
              role == 'tool' && (msg[:content] || msg['content']).to_s.length > 500
            end
            messages = filtered.map do |msg|
              role = (msg[:role] || msg['role']).to_s
              next msg unless role == 'tool'

              content = (msg[:content] || msg['content']).to_s
              content.length > 200 ? msg.merge(content: "#{content[0, 200]}\n[compacted]") : msg
            end

            return messages if estimate_message_tokens(messages) <= target_tokens

            messages = messages.last(messages.size / 2) while messages.size > 2 && estimate_message_tokens(messages) > target_tokens
            messages
          end

          def resolved_context_window
            @resolved_offering_metadata&.dig(:limits, :context_window) ||
              @resolved_offering_metadata&.dig(:context_window) ||
              @resolved_offering_metadata&.dig('limits', 'context_window')
          end

          def estimate_message_tokens(messages)
            messages.sum { |m| ((m[:content] || m['content']).to_s.length / 4.0).ceil }
          end

          def estimate_tool_token_budget
            tools = @request.tools
            return 0 if tools.nil? || tools.empty?

            tool_list = tools.is_a?(Hash) ? tools.values : Array(tools)
            tool_list.sum do |tool|
              json_repr = tool.respond_to?(:to_h) ? Legion::JSON.dump(tool.to_h) : tool.to_s
              (json_repr.length / 3.5).ceil
            end
          end

          def strip_thinking_from_history(messages)
            before_tokens = ContextAccounting.estimate_message_tokens(messages)
            preserve_after = last_user_message_index(messages)
            stripped_count = 0
            result = messages.each_with_index.map do |msg, idx|
              next msg if idx >= preserve_after
              next msg unless (msg[:role] || msg['role']).to_s == 'assistant'

              content = msg[:content] || msg['content']
              next msg unless content.is_a?(String)

              cleaned = strip_leading_thinking_block(content)
              next msg if cleaned == content

              stripped_count += 1
              msg.merge(content: cleaned)
            end

            after_tokens = ContextAccounting.estimate_message_tokens(result)
            saved = [before_tokens - after_tokens, 0].max
            @context_accounting[:component_status][:thinking_strip] = :observed
            if saved.positive?
              @context_accounting[:tokens][:stripped_thinking_estimated_tokens] += saved
              @context_accounting[:counts][:stripped_thinking_message_count] += stripped_count
              @context_accounting[:events] << ContextAccounting.event(
                event_type:    :thinking_stripped,
                component:     :stripped_thinking,
                before_tokens: before_tokens,
                after_tokens:  after_tokens,
                before_count:  messages.size,
                after_count:   result.size,
                metadata:      { stripped_count: stripped_count }
              )
            end

            log.info "[llm][executor] action=strip_thinking_history request_id=#{@request.id} stripped=#{stripped_count}" if stripped_count.positive?
            result
          end

          def strip_leading_thinking_block(text)
            result = text.lstrip
            THINKING_TAG_PAIRS.each do |open_tag, close_tag|
              next unless result.start_with?(open_tag)

              close_idx = result.index(close_tag, open_tag.length)
              return close_idx ? result[(close_idx + close_tag.length)..].lstrip : ''
            end
            text
          end

          def trim_oversized_tool_results(messages)
            max_chars = Legion::Settings[:llm][:tool_result_max_dispatch_chars].to_i
            return messages unless max_chars.positive?

            preserve_after = last_user_message_index(messages)
            trimmed_count = 0
            result = messages.each_with_index.map do |msg, idx|
              next msg if idx >= preserve_after
              next msg unless tool_result_message?(msg)

              content = msg[:content] || msg['content']
              next msg unless content.is_a?(String) && content.length > max_chars

              trimmed_count += 1
              msg.merge(content: "#{content[0, max_chars]}\n\n[TRUNCATED: showing first #{max_chars} of #{content.length} chars. " \
                                 'If you need more content, make multiple smaller targeted requests ' \
                                 '(e.g. read specific line ranges, grep for specific patterns, or request smaller sections).]')
            end

            if trimmed_count.positive?
              log.info "[llm][executor] action=trim_tool_results request_id=#{@request.id} trimmed=#{trimmed_count} " \
                       "max_chars=#{max_chars} preserved_after=#{preserve_after}"
            end
            result
          end

          def last_user_message_index(messages)
            messages.rindex { |m| (m[:role] || m['role']).to_s == 'user' } || messages.size
          end

          def tool_result_message?(msg)
            return false unless msg.is_a?(Hash)

            role = (msg[:role] || msg['role']).to_s
            role == 'tool' || msg.key?(:tool_call_id) || msg.key?('tool_call_id')
          end

          def empty_assistant_message?(msg)
            return false unless msg.is_a?(Hash)
            return false unless (msg[:role] || msg['role']).to_s == 'assistant'

            content = msg[:content] || msg['content']
            has_content = content.is_a?(String) ? !content.strip.empty? : !content.nil?
            return false if has_content

            tool_calls = msg[:tool_calls] || msg['tool_calls']
            return false if tool_calls.is_a?(Array) && tool_calls.any?

            true
          end
        end
      end
    end
  end
end
