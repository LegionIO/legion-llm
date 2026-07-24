# frozen_string_literal: true

require 'legion/logging/helper'
require_relative 'logging'
module Legion
  module LLM
    module Inference
      module Steps
        module TokenBudget
          include Legion::Logging::Helper
          include Steps::Logging

          def step_token_budget
            max_input = @request.extra&.dig(:max_input_tokens)
            session_total = Legion::LLM::Metering::Tokens.total_tokens
            session_limit = Legion::LLM::Metering::Tokens.summary[:session_max_tokens]
            log_step_debug(:token_budget, :checking, max_input_tokens: max_input || 'none',
                                                     session_total: session_total, session_limit: session_limit || 'none')

            check_input_cap(max_input) if max_input&.positive?
            check_session_budget
            log_step_debug(:token_budget, :passed, max_input_tokens: max_input || 'none')
            @applied_signals[:envelope_keys] << 'token_budget:passed' if @applied_signals.is_a?(Hash)
          rescue Legion::LLM::TokenBudgetExceeded
            log_step_info(:token_budget, :blocked)
            raise
          rescue StandardError => e
            @warnings << { type: :token_budget_check_failed, message: e.message }
            handle_exception(e, level: :warn, operation: 'llm.pipeline.steps.token_budget')
          end

          private

          def check_input_cap(max_input)
            estimated = estimate_input_tokens
            if estimated <= max_input
              log_step_debug(:token_budget, :input_cap_passed, estimated_tokens: estimated, max_input_tokens: max_input)
              return
            end

            log_step_info(:token_budget, :input_cap_exceeded, estimated_tokens: estimated, max_input_tokens: max_input)
            raise Legion::LLM::TokenBudgetExceeded,
                  "request input estimate #{estimated} tokens exceeds max_input_tokens #{max_input}"
          end

          def check_session_budget
            unless Legion::LLM::Metering::Tokens.session_exceeded?
              log_step_debug(:token_budget, :session_budget_passed)
              return
            end

            limit = Legion::LLM::Metering::Tokens.summary[:session_max_tokens]
            total = Legion::LLM::Metering::Tokens.total_tokens
            log_step_info(:token_budget, :session_budget_exceeded, total_tokens: total, limit: limit)
            raise Legion::LLM::TokenBudgetExceeded,
                  "session token budget exceeded: #{total} >= #{limit}"
          end

          # One oracle: same estimator the router filter and dispatch guard use.
          # ContextAccounting walks canonical structs / content blocks; the
          # injected system carries baseline + history + RAG + skills.
          def estimate_input_tokens
            injected_system = EnrichmentInjector.inject(
              system:      @request.system,
              enrichments: @enrichments || {}
            )
            ContextAccounting.estimate_message_tokens(@request.messages) +
              ContextAccounting.estimate_text_tokens(injected_system)
          end
        end
      end
    end
  end
end
