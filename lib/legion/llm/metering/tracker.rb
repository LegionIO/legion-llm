# frozen_string_literal: true

require 'legion/logging/helper'
require 'legion/llm/metering/estimator'
module Legion
  module LLM
    module Metering
      module Recorder
        extend Legion::Logging::Helper

        class << self
          # Records a completed LLM request and calculates its cost.
          #
          # @param model         [String]       model identifier
          # @param input_tokens  [Integer]      number of input tokens consumed
          # @param output_tokens [Integer]      number of output tokens produced
          # @param provider      [Symbol, nil]  provider (informational)
          # @return [Hash] the recorded entry
          def record(model:, input_tokens:, output_tokens:, provider: nil)
            cost = Pricing.estimate(model_id: model, input_tokens: input_tokens, output_tokens: output_tokens)

            entry = {
              model:         model,
              provider:      provider,
              input_tokens:  input_tokens,
              output_tokens: output_tokens,
              cost_usd:      cost.round(6),
              recorded_at:   Time.now
            }

            records << entry
            log.debug "[LLM::CostTracker] #{model}: #{input_tokens}+#{output_tokens} tokens = $#{cost.round(6)}"
            entry
          end

          # Returns a cost summary, optionally filtered by a start time.
          #
          # @param since [Time, nil] include only records on or after this time
          # @return [Hash] with :total_cost_usd, :total_requests, token totals, and :by_model breakdown
          def summary(since: nil)
            subset = since ? records.select { |r| r[:recorded_at] >= since } : records.dup

            {
              total_cost_usd:      subset.sum { |r| r[:cost_usd] }.round(6),
              total_requests:      subset.size,
              total_input_tokens:  subset.sum { |r| r[:input_tokens] },
              total_output_tokens: subset.sum { |r| r[:output_tokens] },
              by_model:            subset.group_by { |r| r[:model] }.transform_values do |rs|
                {
                  cost_usd: rs.sum { |r| r[:cost_usd] }.round(6),
                  requests: rs.size
                }
              end
            }
          end

          # Clears all recorded entries.
          def clear
            @records = []
          end

          # Returns pricing for a model, preferring settings-defined overrides.
          #
          # @param model [String] model identifier
          # @return [Hash] with :input and :output keys (per-1M-token USD)
          def pricing_for(model)
            input, output = Pricing.resolve_price(model)
            { input: input, output: output }
          end

          private

          def records
            @records ||= []
          end
        end
      end
    end
  end
end
