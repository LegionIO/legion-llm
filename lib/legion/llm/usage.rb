# frozen_string_literal: true

module Legion
  module LLM
    # Immutable value object representing token usage for a provider response.
    #
    # input_tokens       - Integer tokens consumed by the prompt
    # output_tokens      - Integer tokens in the generated response
    # cache_read_tokens  - Integer tokens served from prompt cache (e.g. Anthropic cache_read)
    # cache_write_tokens - Integer tokens written to prompt cache
    # total_tokens       - Integer total; auto-calculated as input + output when not provided
    Usage = ::Data.define(
      :input_tokens,
      :output_tokens,
      :cache_read_tokens,
      :cache_write_tokens,
      :total_tokens
    ) do
      def initialize(input_tokens: 0, output_tokens: 0, cache_read_tokens: 0, cache_write_tokens: 0, total_tokens: nil)
        super(
          input_tokens:,
          output_tokens:,
          cache_read_tokens:,
          cache_write_tokens:,
          total_tokens:       total_tokens || (input_tokens + output_tokens)
        )
      end
    end
  end
end
