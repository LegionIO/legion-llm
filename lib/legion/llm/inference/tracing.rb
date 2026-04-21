# frozen_string_literal: true

module Legion
  module LLM
    module Inference
      module Tracing
        module_function

        def init(existing: nil)
          if existing && existing[:trace_id]
            {
              trace_id:       existing[:trace_id],
              span_id:        SecureRandom.hex(8),
              parent_span_id: existing[:span_id],
              correlation_id: existing[:correlation_id],
              baggage:        existing[:baggage] || {}
            }
          else
            {
              trace_id:       SecureRandom.hex(16),
              span_id:        SecureRandom.hex(8),
              parent_span_id: nil,
              correlation_id: nil,
              baggage:        {}
            }
          end
        end

        def exchange_id
          "exch_#{SecureRandom.hex(12)}"
        end
      end
    end
  end
end
