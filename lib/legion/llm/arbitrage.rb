# frozen_string_literal: true

require 'legion/logging/helper'
module Legion
  module LLM
    module Arbitrage
      extend Legion::Logging::Helper
      # Default cost table: per-1M-token input/output prices in USD.
      # Overridable via settings: llm.arbitrage.cost_table
      DEFAULT_COST_TABLE = {
        'claude-sonnet-4-6'                 => { input: 3.0, output: 15.0 },
        'us.anthropic.claude-sonnet-4-6-v1' => { input: 3.0, output: 15.0 },
        'gpt-4o'                            => { input: 2.5,  output: 10.0 },
        'gpt-4o-mini'                       => { input: 0.15, output: 0.60 },
        'gemini-2.0-flash'                  => { input: 0.10, output: 0.40 },
        'llama3'                            => { input: 0.0,  output: 0.0  }
      }.freeze

      class << self
        # Returns true when arbitrage is enabled in settings.
        def enabled?
          settings.fetch(:enabled, false) == true
        end

        # Returns the estimated cost for a request with the given token counts.
        #
        # @param model [String] model identifier
        # @param input_tokens [Integer] estimated number of input tokens
        # @param output_tokens [Integer] estimated number of output tokens
        # @return [Float, nil] estimated cost in USD, or nil if model not in table
        def estimated_cost(model:, input_tokens: 1000, output_tokens: 500)
          entry = cost_table[model.to_s]
          return nil if entry.nil?

          ((entry[:input] * input_tokens) + (entry[:output] * output_tokens)) / 1_000_000.0
        end

        # Selects the cheapest model that meets the capability and quality floor requirements.
        #
        # @param capability [String, Symbol] required capability tier (e.g., :basic, :moderate, :reasoning)
        # @param max_cost [Float, nil] maximum acceptable cost per typical request (USD); nil means no limit
        # @param input_tokens [Integer] estimated input tokens for cost calculation
        # @param output_tokens [Integer] estimated output tokens for cost calculation
        # @return [String, nil] cheapest eligible model ID, or nil if none qualify
        def cheapest_for(capability: :moderate, max_cost: nil, input_tokens: 1000, output_tokens: 500)
          return nil unless enabled?

          quality_floor = settings.fetch(:quality_floor, 0.7)
          eligible = eligible_models(capability: capability, quality_floor: quality_floor)

          scored = eligible.filter_map do |model|
            cost = estimated_cost(model: model, input_tokens: input_tokens, output_tokens: output_tokens)
            next if cost.nil?
            next if max_cost && cost > max_cost

            [model, cost]
          end

          return nil if scored.empty?

          selected = scored.min_by { |_model, cost| cost }&.first
          log.debug("Arbitrage selected model=#{selected} capability=#{capability}")
          selected
        end

        # Returns the merged cost table: defaults overridden by any settings-defined entries.
        def cost_table
          overrides = settings.fetch(:cost_table, {})
          return DEFAULT_COST_TABLE if overrides.nil? || overrides.empty?

          merged = DEFAULT_COST_TABLE.dup
          overrides.each do |model, costs|
            entry = costs.transform_keys(&:to_sym)
            merged[model.to_s] = entry
          end
          merged
        end

        private

        def settings
          llm = Legion::Settings[:llm]
          return {} unless llm.is_a?(Hash)

          arb = llm[:arbitrage] || llm['arbitrage'] || {}
          arb.is_a?(Hash) ? arb.transform_keys(&:to_sym) : {}
        rescue StandardError => e
          handle_exception(e, level: :warn)
          {}
        end

        # Returns models eligible for the given capability tier based on quality floor.
        # The quality floor maps capability tiers to minimum acceptable quality scores (0.0-1.0).
        # Models that are local (cost 0) always qualify for :basic capability.
        def eligible_models(capability:, quality_floor: 0.7)
          cap = capability.to_sym

          disqualified_for_reasoning = %w[gpt-4o-mini gemini-2.0-flash llama3]

          models = cost_table.keys.reject do |model|
            cap == :reasoning && disqualified_for_reasoning.include?(model)
          end

          return models unless defined?(Legion::LLM::QualityChecker) && QualityChecker.respond_to?(:model_score)

          models.select do |model|
            score = QualityChecker.model_score(model)
            score.nil? || score >= quality_floor
          end
        end
      end
    end
  end
end
