# frozen_string_literal: true

module Legion
  module LLM
    module CostTracker
      # Default per-1M-token pricing in USD (input / output).
      # Overridable via Legion::Settings[:llm][:pricing].
      DEFAULT_PRICING = {
        'claude-sonnet-4-6' => { input: 3.0,  output: 15.0 },
        'claude-haiku-4-5'  => { input: 0.80, output: 4.0  },
        'claude-opus-4-6'   => { input: 15.0, output: 75.0 },
        'gpt-4o'            => { input: 2.50, output: 10.0 },
        'gpt-4o-mini'       => { input: 0.15, output: 0.60 }
      }.freeze

      class << self
        # Records a completed LLM request and calculates its cost.
        #
        # @param model         [String]       model identifier
        # @param input_tokens  [Integer]      number of input tokens consumed
        # @param output_tokens [Integer]      number of output tokens produced
        # @param provider      [Symbol, nil]  provider (informational)
        # @return [Hash] the recorded entry
        def record(model:, input_tokens:, output_tokens:, provider: nil)
          pricing = pricing_for(model)
          cost    = (input_tokens * pricing[:input] / 1_000_000.0) +
                    (output_tokens * pricing[:output] / 1_000_000.0)

          entry = {
            model:         model,
            provider:      provider,
            input_tokens:  input_tokens,
            output_tokens: output_tokens,
            cost_usd:      cost.round(6),
            recorded_at:   Time.now
          }

          records << entry
          Legion::Logging.debug "[LLM::CostTracker] #{model}: #{input_tokens}+#{output_tokens} tokens = $#{cost.round(6)}"
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
          custom = settings_pricing
          custom[model.to_s] || DEFAULT_PRICING[model.to_s] || { input: 5.0, output: 15.0 }
        end

        private

        def records
          @records ||= []
        end

        def settings_pricing
          return {} unless defined?(Legion::Settings)

          pricing = Legion::Settings.dig(:'legion-llm', :pricing)
          pricing.is_a?(Hash) ? pricing : {}
        rescue StandardError => e
          Legion::Logging.warn("CostTracker settings unavailable: #{e.message}") if defined?(Legion::Logging)
          {}
        end
      end
    end
  end
end
