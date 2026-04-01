# frozen_string_literal: true

module Legion
  module LLM
    class LLMError < StandardError
      def retryable? = false
    end

    class AuthError < LLMError; end

    class RateLimitError < LLMError
      attr_reader :retry_after

      def initialize(msg = nil, retry_after: nil)
        @retry_after = retry_after
        super(msg)
      end

      def retryable? = true
    end

    class ContextOverflow < LLMError
      def retryable? = true
    end

    class ProviderError < LLMError
      def retryable? = true
    end

    class ProviderDown < LLMError; end

    class UnsupportedCapability < LLMError; end

    class PipelineError < LLMError
      attr_reader :step

      def initialize(msg = nil, step: nil)
        @step = step
        super(msg)
      end
    end

    class TokenBudgetExceeded < LLMError; end
  end
end
