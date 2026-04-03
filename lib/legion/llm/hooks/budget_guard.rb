# frozen_string_literal: true

require 'legion/logging/helper'
module Legion
  module LLM
    module Hooks
      module BudgetGuard
        extend Legion::Logging::Helper

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

          log.warn("[LLM::BudgetGuard] blocked: spent=$#{spent.round(4)} >= limit=$#{limit}")
          {
            action:   :block,
            response: budget_exceeded_response(model, spent, limit)
          }
        rescue StandardError => e
          handle_exception(e, level: :debug)
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
          handle_exception(e, level: :debug)
          0.0
        end
      end
    end
  end
end
