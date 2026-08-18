# frozen_string_literal: true

module Legion
  module LLM
    module Settings
      # API-surface settings. Owning surface for the SSOT v3
      # `routing_too_early_retry_after` value (controlling design D16): the
      # Retry-After emitted on compatibility 503/529 responses that map an
      # internal TooEarly/ServiceUnavailable/AttemptsExhausted rejection.
      module API
        extend Legion::Logging::Helper

        def self.defaults
          {
            use_namespaces:                   true,
            batch_pool_size:                  4,
            auth:                             {
              enabled:      false,
              api_keys:     [],
              pass_through: false
            },
            # G21 — X-Legion-Format and X-Legion-Debug surface. Default ON for
            # lite/dev because the envelope leaks routing/escalation internals;
            # production deployments must explicitly opt in.
            debug_formats:                    Legion::LLM::Settings.debug_formats_defaults,
            # opus M5 / G14: Retry-After seconds sent with EscalationExhausted (503).
            # SDKs auto-retry on 503; this value tells them when to retry.
            escalation_exhausted_retry_after: 5,
            # SSOT v3 D16: Retry-After (seconds) sent on compatibility 503/529
            # responses derived from an internal too_early/service_unavailable/
            # attempts_exhausted routing rejection. Native routes keep 425 and
            # this same value. Valid range 1..30; not a provider/model default.
            routing_too_early_retry_after:    1
          }
        end
      end
    end
  end
end
