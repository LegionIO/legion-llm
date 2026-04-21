# frozen_string_literal: true

module Legion
  module LLM
    module Metering
      module Pricing
        # Prices per 1M tokens [input, output] in USD
        # Source: published API pricing as of 2026-03
        PRICING = {
          'claude-opus-4-6'   => [15.0, 75.0],
          'claude-sonnet-4-6' => [3.0, 15.0],
          'claude-haiku-4-5'  => [0.80, 4.0],
          'claude-3-5-sonnet' => [3.0, 15.0],
          'claude-3-haiku'    => [0.25, 1.25],
          'gpt-4o'            => [2.50, 10.0],
          'gpt-4o-mini'       => [0.15, 0.60],
          'gpt-4-turbo'       => [10.0, 30.0],
          'o3'                => [10.0, 40.0],
          'o3-mini'           => [1.10, 4.40],
          'o4-mini'           => [1.10, 4.40],
          'gemini-2.5-pro'    => [1.25, 10.0],
          'gemini-2.5-flash'  => [0.15, 0.60],
          'gemini-2.0-flash'  => [0.10, 0.40]
        }.freeze

        DEFAULT_PRICE = [1.0, 3.0].freeze

        module_function

        def estimate(model_id:, input_tokens: 0, output_tokens: 0, **)
          price = resolve_price(model_id)
          input_cost  = (input_tokens.to_i / 1_000_000.0) * price[0]
          output_cost = (output_tokens.to_i / 1_000_000.0) * price[1]
          (input_cost + output_cost).round(6)
        end

        def resolve_price(model_id)
          return DEFAULT_PRICE unless model_id

          normalized = model_id.to_s.downcase
          PRICING[normalized] || fuzzy_match(normalized) || DEFAULT_PRICE
        end

        def fuzzy_match(normalized)
          PRICING.each do |key, price|
            return price if normalized.include?(key) || key.include?(normalized)
          end
          nil
        end
      end
    end
  end
end
