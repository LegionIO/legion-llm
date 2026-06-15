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

    class DaemonUnavailableError < LLMError; end

    class RoutingUnavailable < LLMError
      attr_reader :status_code, :code

      def initialize(message = 'Routing unavailable', status_code: 503, code: 'routing_unavailable')
        @status_code = status_code
        @code = code
        super(message)
      end
    end

    class RoutingTooEarly < RoutingUnavailable
      def initialize(message = 'Routing prerequisites are not confirmed yet')
        super(message, status_code: 425, code: 'routing_too_early')
      end
    end

    class RoutingFailedDependency < RoutingUnavailable
      def initialize(message = 'No provider instance satisfies routing prerequisites')
        super(message, status_code: 424, code: 'routing_failed_dependency')
      end
    end
  end
end
