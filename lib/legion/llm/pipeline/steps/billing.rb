# frozen_string_literal: true

module Legion
  module LLM
    module Pipeline
      module Steps
        module Billing
          def step_billing
            return unless @request.billing

            billing        = @request.billing
            cap            = billing[:spending_cap]
            estimated_cost = cap ? estimate_request_cost : nil

            if cap && estimated_cost > cap
              raise Legion::LLM::PipelineError.new(
                "budget_exceeded: estimated cost #{estimated_cost.round(6)} exceeds cap #{cap}",
                step: :billing
              )
            end

            @enrichments['billing:budget_check'] = {
              budget_id:          billing[:budget_id],
              cost_center:        billing[:cost_center],
              spending_cap:       cap,
              estimated_cost_usd: estimated_cost,
              timestamp:          Time.now
            }.compact

            @audit[:'billing:budget_check'] = {
              outcome:     :success,
              detail:      "budget_id=#{billing[:budget_id]}, cap=#{cap}, estimated=#{estimated_cost}",
              duration_ms: 0,
              timestamp:   Time.now
            }

            @timeline.record(
              category:  :audit, key: 'billing:budget_check',
              direction: :internal, detail: "outcome=success, budget_id=#{billing[:budget_id]}",
              from:      'pipeline', to: 'billing'
            )
          end

          private

          def estimate_request_cost
            model_id     = @request.routing[:model]
            input_tokens = @request.messages.sum { |m| m[:content].to_s.length } / 4
            CostEstimator.estimate(model_id: model_id, input_tokens: input_tokens, output_tokens: 0)
          end
        end
      end
    end
  end
end
