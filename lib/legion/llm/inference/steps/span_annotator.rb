# frozen_string_literal: true

require 'legion/logging/helper'

module Legion
  module LLM
    module Inference
      module Steps
        module SpanAnnotator
          extend Legion::Logging::Helper

          module_function

          STEP_ATTRIBUTE_BUILDERS = {
            rbac:               lambda { |audit, _enrichments|
              entry = audit[:'rbac:permission_check']
              return {} unless entry.is_a?(Hash)

              {
                'rbac.outcome'     => entry[:outcome]&.to_s,
                'rbac.duration_ms' => entry[:duration_ms]
              }.compact
            },
            classification:     lambda { |_audit, enrichments|
              scan = enrichments['classification:scan']
              return {} unless scan.is_a?(Hash)

              {
                'classification.pii_detected' => scan[:contains_pii],
                'classification.phi_detected' => scan[:contains_phi]
              }.compact
            },
            billing:            lambda { |_audit, enrichments|
              check = enrichments['billing:budget_check']
              return {} unless check.is_a?(Hash)

              {
                'billing.estimated_cost_usd' => check[:estimated_cost_usd]
              }.compact
            },
            rag_context:        lambda { |_audit, enrichments|
              ctx = enrichments['rag:context_retrieval']
              return {} unless ctx.is_a?(Hash)

              data = ctx[:data] || {}
              {
                'rag.entry_count' => data[:count],
                'rag.strategy'    => data[:strategy]&.to_s
              }.compact
            },
            routing:            lambda { |audit, _enrichments|
              entry = audit[:'routing:provider_selection']
              return {} unless entry.is_a?(Hash)

              data = entry[:data] || {}
              {
                'gen_ai.request.model' => nil,
                'routing.strategy'     => data[:strategy]&.to_s,
                'routing.tier'         => data[:tier]&.to_s
              }.compact
            },
            provider_call:      lambda { |audit, _enrichments|
              entry = audit[:'provider:response']
              return {} unless entry.is_a?(Hash)

              data = entry[:data] || {}
              {
                'gen_ai.usage.input_tokens'  => data[:input_tokens],
                'gen_ai.usage.output_tokens' => data[:output_tokens],
                'provider.duration_ms'       => entry[:duration_ms]
              }.compact
            },
            tool_calls:         lambda { |_audit, _enrichments|
              {}
            },
            confidence_scoring: lambda { |_audit, enrichments|
              score_data = enrichments['confidence:score']
              return {} unless score_data.is_a?(Hash)

              {
                'confidence.score' => score_data[:score],
                'confidence.band'  => score_data[:band]&.to_s
              }.compact
            }
          }.freeze

          def attributes_for(step_name, audit: {}, enrichments: {})
            builder = STEP_ATTRIBUTE_BUILDERS[step_name.to_sym]
            return {} unless builder

            builder.call(audit || {}, enrichments || {})
          rescue StandardError => e
            handle_exception(e, level: :debug, operation: 'llm.pipeline.steps.span_annotator.attributes_for', step: step_name)
            {}
          end
        end
      end
    end
  end
end
