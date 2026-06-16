# frozen_string_literal: true

module Legion
  module LLM
    module Inference
      module ContextAccounting
        TOKEN_CHAR_DIVISOR = 4
        SCHEMA_VERSION = 1

        TOKEN_KEYS = %i[
          request_message_estimated_tokens
          loaded_history_estimated_tokens
          curated_history_estimated_tokens
          curation_saved_estimated_tokens
          stripped_thinking_estimated_tokens
          archived_history_estimated_tokens
          archive_saved_estimated_tokens
          context_window_saved_estimated_tokens
          rag_injected_estimated_tokens
          system_prompt_estimated_tokens
          baseline_system_estimated_tokens
          tool_definition_estimated_tokens
          final_context_estimated_tokens
        ].freeze

        COUNT_KEYS = %i[
          loaded_history_message_count
          curated_history_message_count
          archived_history_message_count
          stripped_thinking_message_count
          context_window_message_count_before
          context_window_message_count_after
          rag_entry_count
          tool_definition_count
        ].freeze

        CONTEXT_ACCOUNTING_STATUS_RANK = {
          'missing'             => 0,
          'profile_skipped'     => 1,
          'partial'             => 2,
          'estimated'           => 3,
          'provider_reconciled' => 4
        }.freeze

        module_function

        def empty(status: :estimated)
          {
            schema_version:   SCHEMA_VERSION,
            status:           status,
            estimator:        { name: :legion_char_div_four, version: 1 },
            counts:           COUNT_KEYS.to_h { |key| [key, 0] },
            tokens:           TOKEN_KEYS.to_h { |key| [key, 0] },
            reconciliation:   {},
            component_status: {
              context_load:   :not_observed,
              curation:       :not_observed,
              archive:        :not_observed,
              rag:            :not_observed,
              tools:          :not_observed,
              system:         :not_observed,
              context_window: :not_observed,
              thinking_strip: :not_observed
            },
            events:           []
          }
        end

        def estimate_text_tokens(text)
          (text.to_s.length / TOKEN_CHAR_DIVISOR.to_f).ceil
        end

        def estimate_message_tokens(messages)
          Array(messages).sum { |message| estimate_text_tokens(message_text(message)) }
        end

        def estimate_json_tokens(value)
          estimate_text_tokens(Legion::JSON.dump(value || {}))
        end

        def message_text(message)
          return message.to_s unless message.is_a?(Hash)

          content = message[:content]
          content_text(content)
        end

        def content_text(content)
          return content.to_s unless content.is_a?(Array)

          content.map do |part|
            part.is_a?(Hash) ? (part[:text] || part[:content]).to_s : part.to_s
          end.join("\n")
        end

        def event(event_type:, component:, before_tokens:, after_tokens:, before_count: 0, after_count: 0, metadata: {})
          {
            event_type:              event_type,
            component:               component,
            estimated_tokens_before: before_tokens.to_i,
            estimated_tokens_after:  after_tokens.to_i,
            estimated_tokens_delta:  after_tokens.to_i - before_tokens.to_i,
            message_count_before:    before_count.to_i,
            message_count_after:     after_count.to_i,
            metadata:                metadata
          }
        end
      end
    end
  end
end
