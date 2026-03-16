# frozen_string_literal: true

module Legion
  module LLM
    module EscalationHistory
      attr_accessor :final_resolution, :escalation_chain

      def escalation_history
        @escalation_history ||= []
      end

      def escalated?
        escalation_history.size > 1
      end

      def record_escalation_attempt(model:, provider:, tier:, outcome:, failures:, duration_ms:)
        escalation_history << {
          model:       model,
          provider:    provider,
          tier:        tier,
          outcome:     outcome,
          failures:    failures,
          duration_ms: duration_ms
        }
      end
    end
  end
end
