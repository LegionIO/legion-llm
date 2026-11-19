# frozen_string_literal: true

require 'legion/logging/helper'

module Legion
  module LLM
    module Metering
      module Pricing
        extend Legion::Logging::Helper

        module_function

        def estimate(model_id:, input_tokens: 0, output_tokens: 0, **)
          price = resolve_price(model_id)
          input_cost  = (input_tokens.to_i / 1_000_000.0) * price[0]
          output_cost = (output_tokens.to_i / 1_000_000.0) * price[1]
          (input_cost + output_cost).round(6)
        end

        def resolve_price(model_id)
          configured = Legion::Settings[:llm][:pricing]
          raise ArgumentError, 'llm.pricing must be a Hash of model rates' unless configured.is_a?(Hash)

          prices = configured.transform_keys { |name| name.to_s.downcase }
          normalized = model_id.to_s.downcase
          key = prices.key?(normalized) ? normalized : matching_model(normalized, prices)
          price = key ? prices.fetch(key) : Legion::Settings.dig(:llm, :metering, :unknown_model_price)
          validate_price(price)
        end

        def matching_model(normalized, prices)
          return if normalized.empty?

          # Decorated model identifiers use the most specific configured name.
          # A short/empty unknown identifier must not match arbitrary models.
          prices.keys.reject(&:empty?).sort_by { |name| [-name.length, name] }
                .find { |name| normalized.include?(name) }
        end

        def validate_price(price)
          rates = [price[:input] || price['input'], price[:output] || price['output']] if price.is_a?(Hash)
          return rates.freeze if rates&.all? { |rate| rate.is_a?(Numeric) && rate.real? && rate.finite? && rate >= 0 }

          raise ArgumentError, 'LLM pricing must define finite nonnegative input and output rates per million tokens'
        end
      end
    end
  end
end
