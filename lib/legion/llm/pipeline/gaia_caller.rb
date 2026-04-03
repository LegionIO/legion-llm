# frozen_string_literal: true

require 'legion/logging/helper'

module Legion
  module LLM
    module Pipeline
      module GaiaCaller
        module_function
        extend Legion::Logging::Helper

        def chat(message:, phase: 'unknown', tick_trace_id: nil, tick_span_id: nil, caller: nil, **kwargs)
          log.info("[llm][gaia] chat phase=#{phase} model=#{kwargs[:model] || 'default'}")
          request = Request.build(
            messages: [{ role: :user, content: message }],
            system:   kwargs[:system],
            routing:  { provider: kwargs[:provider], model: kwargs[:model] }.compact,
            caller:   caller || gaia_caller(phase),
            tracing:  gaia_tracing(phase, tick_trace_id, tick_span_id)
          )
          Executor.new(request).call
        end

        def structured(message:, schema:, phase: 'unknown', tick_trace_id: nil, tick_span_id: nil, caller: nil, **kwargs)
          log.info("[llm][gaia] structured phase=#{phase} model=#{kwargs[:model] || 'default'}")
          request = Request.build(
            messages:        [{ role: :user, content: message }],
            system:          kwargs[:system],
            routing:         { provider: kwargs[:provider], model: kwargs[:model] }.compact,
            response_format: { type: :json_schema, schema: schema },
            caller:          caller || gaia_caller(phase),
            tracing:         gaia_tracing(phase, tick_trace_id, tick_span_id)
          )
          Executor.new(request).call
        end

        def embed(text:, **)
          log.info("[llm][gaia] embed text_chars=#{text.to_s.length}")
          LLM.embed(text, **)
        end

        def gaia_caller(phase)
          {
            requested_by: {
              identity:   "gaia:tick:#{phase}",
              type:       :system,
              credential: :internal,
              name:       "GAIA #{phase.to_s.tr('_', ' ').capitalize}"
            }
          }
        end

        def gaia_tracing(phase, trace_id, span_id)
          {
            trace_id:       trace_id || SecureRandom.hex(16),
            span_id:        SecureRandom.hex(8),
            parent_span_id: span_id,
            correlation_id: "gaia:tick:#{phase}"
          }
        end
      end
    end
  end
end
