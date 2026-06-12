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
            return messages unless context_window&.positive?

            threshold = (context_window * 0.90).to_i
            estimated = estimate_message_tokens(messages)
            return messages if estimated <= threshold

            log.warn "[llm][executor] action=context_compaction request_id=#{@request.id} " \
                     "estimated_tokens=#{estimated} context_window=#{context_window} threshold=#{threshold}"

            preserve_after = last_user_message_index(messages)
            recent = messages[preserve_after..]
            older = messages[0...preserve_after]

            target_tokens = threshold - estimate_message_tokens(recent)
            compacted = compact_to_fit(older, target_tokens)

            log.info "[llm][executor] action=context_compaction_complete request_id=#{@request.id} " \
                     "before=#{messages.size} after=#{compacted.size + recent.size} " \
                     "tokens_before=#{estimated} tokens_after=#{estimate_message_tokens(compacted + recent)}"
            compacted + recent
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

            half = messages.size / 2
            messages.last(half)
          end

          def resolved_context_window
            @resolved_offering_metadata&.dig(:limits, :context_window) ||
              @resolved_offering_metadata&.dig(:context_window) ||
              @resolved_offering_metadata&.dig('limits', 'context_window')
          end

          def estimate_message_tokens(messages)
            messages.sum { |m| ((m[:content] || m['content']).to_s.length / 4.0).ceil }
          end

          def strip_thinking_from_history(messages)
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
              msg.merge(content: "#{content[0, max_chars]}\n[truncated — #{content.length} chars total]")
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
