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

    # Raised when a request targets a model excluded by a provider's configured
    # model_whitelist / model_blacklist. This is a terminal policy outcome, not a
    # provider failure: it is non-retryable (inherited) and must not be escalated,
    # must not trip a circuit breaker, and must not deny-record the model — the
    # escalation loop re-raises it immediately rather than trying the next model.
    class ModelNotAllowed < LLMError
      attr_reader :provider, :model

      def initialize(message = nil, provider: nil, model: nil)
        @provider = provider
        @model = model
        super(message || "model #{model.inspect} is not permitted by the configured policy for provider #{provider.inspect}")
      end
    end

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
      attr_reader :status_code, :code, :reasons

      def initialize(message = 'Routing unavailable', status_code: 503, code: 'routing_unavailable', reasons: [])
        @status_code = status_code
        @code = code
        @reasons = reasons
        super(message)
      end

      def retryable? = true
    end

    class RoutingTooEarly < RoutingUnavailable
      def initialize(message = 'Routing prerequisites are not confirmed yet', reasons: [])
        super(message, status_code: 425, code: 'routing_too_early', reasons: reasons)
      end

      def retryable? = true
    end

    class RoutingFailedDependency < RoutingUnavailable
      def initialize(message = 'No provider instance satisfies routing prerequisites', reasons: [])
        super(message, status_code: 424, code: 'routing_failed_dependency', reasons: reasons)
      end

      # 424 indicates a state prerequisite is unmet (circuit open, model denied, capability
      # missing) — retrying without a state change is futile. Override the parent's `true`.
      def retryable? = false
    end
  end
end
