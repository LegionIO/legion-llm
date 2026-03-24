# frozen_string_literal: true

module Legion
  module LLM
    module Hooks
      module BudgetGuard
        module_function

        def install
          Legion::LLM::Hooks.before_chat do |model:, **|
            check_budget(model)
          end
        end

        def check_budget(model)
          return nil unless enforcing?

          limit = session_budget
          spent = CostTracker.summary[:total_cost_usd]
          return nil if spent < limit

          Legion::Logging.warn("[LLM::BudgetGuard] blocked: spent=$#{spent.round(4)} >= limit=$#{limit}") if defined?(Legion::Logging)
          {
            action:   :block,
            response: budget_exceeded_response(model, spent, limit)
          }
        rescue StandardError => e
          Legion::Logging.debug("[LLM::BudgetGuard] check failed: #{e.message}") if defined?(Legion::Logging)
          nil
        end

        def enforcing?
          session_budget.positive?
        end

        def session_budget
          budget_setting.to_f
        end

        def remaining
          limit = session_budget
          return Float::INFINITY unless limit.positive?

          spent = CostTracker.summary[:total_cost_usd]
          [(limit - spent), 0.0].max
        end

        def status
          limit = session_budget
          spent = CostTracker.summary[:total_cost_usd]
          {
            enforcing:     limit.positive?,
            budget_usd:    limit,
            spent_usd:     spent.round(6),
            remaining_usd: limit.positive? ? [(limit - spent), 0.0].max.round(6) : nil,
            ratio:         limit.positive? ? (spent / limit).round(4) : 0.0
          }
        end

        def budget_exceeded_response(model, spent, limit)
          {
            error:      'budget_exceeded',
            message:    "Session budget of $#{limit} exceeded (spent: $#{spent.round(4)}). " \
                        "Model #{model} request blocked.",
            spent_usd:  spent.round(6),
            budget_usd: limit
          }
        end

        def budget_setting
          return 0.0 unless defined?(Legion::Settings)

          settings = Legion::Settings.dig(:llm, :budget, :session_usd)
          settings.to_f
        rescue StandardError => e
          Legion::Logging.debug("BudgetGuard#budget_setting failed: #{e.message}") if defined?(Legion::Logging)
          0.0
        end
      end
    end
  end
end
