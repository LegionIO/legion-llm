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
            log_step_debug(:token_budget, :checking, max_input_tokens: max_input || 'none')
            check_input_cap(max_input) if max_input&.positive?
            check_session_budget
            log_step_debug(:token_budget, :passed, max_input_tokens: max_input || 'none')
          rescue Legion::LLM::TokenBudgetExceeded
            log_step_info(:token_budget, :blocked)
            raise
          rescue StandardError => e
            @warnings << { type: :token_budget_check_failed, message: e.message }
            handle_exception(e, level: :debug, operation: 'llm.pipeline.steps.token_budget')
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

          def estimate_input_tokens
            content_chars = @request.messages.sum { |m| message_content_chars(m[:content]) }
            injected_system = EnrichmentInjector.inject(
              system:      @request.system,
              enrichments: @enrichments || {}
            )
            system_chars = injected_system.to_s.length
            (content_chars + system_chars) / 4
          end

          def message_content_chars(content)
            return content.to_s.length unless content.is_a?(Array)

            content.sum do |part|
              part.is_a?(Hash) ? (part[:text] || part['text']).to_s.length : part.to_s.length
            end
          end
        end
      end
    end
  end
end
