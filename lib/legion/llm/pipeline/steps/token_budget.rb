# frozen_string_literal: true

module Legion
  module LLM
    module Pipeline
      module Steps
        module TokenBudget
          def step_token_budget
            max_input = @request.extra&.dig(:max_input_tokens)
            check_input_cap(max_input) if max_input&.positive?
            check_session_budget
          rescue Legion::LLM::TokenBudgetExceeded
            raise
          rescue StandardError => e
            @warnings << { type: :token_budget_check_failed, message: e.message }
            Legion::Logging.debug "[pipeline] token_budget step failed: #{e.message}"
          end

          private

          def check_input_cap(max_input)
            estimated = estimate_input_tokens
            return unless estimated > max_input

            raise Legion::LLM::TokenBudgetExceeded,
                  "request input estimate #{estimated} tokens exceeds max_input_tokens #{max_input}"
          end

          def check_session_budget
            return unless TokenTracker.session_exceeded?

            limit = TokenTracker.summary[:session_max_tokens]
            total = TokenTracker.total_tokens
            raise Legion::LLM::TokenBudgetExceeded,
                  "session token budget exceeded: #{total} >= #{limit}"
          end

          def estimate_input_tokens
            content_chars = @request.messages.sum { |m| m[:content].to_s.length }
            system_chars  = @request.system.to_s.length
            (content_chars + system_chars) / 4
          end
        end
      end
    end
  end
end
