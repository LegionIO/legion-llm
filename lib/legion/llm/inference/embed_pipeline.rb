# frozen_string_literal: true

require 'legion/logging/helper'

require_relative '../call/embeddings'
require_relative '../metering'

module Legion
  module LLM
    module Inference
      # Slim governed entry for embedding requests (SSOT v3 §21). Selection,
      # dispatch, and the content-addressed cache are all owned by the migrated
      # `Call::Embeddings` (which selects the exact lane BEFORE any cache lookup,
      # per §21.2). This pipeline no longer reads embedding provider/model/instance
      # defaults and no longer keys a cache ahead of selection — it normalizes the
      # caller input, routes through `Call::Embeddings.generate`, and emits the
      # existing metering event. Typed routing errors propagate to the caller.
      #
      #   normalize -> Call::Embeddings.generate (select -> cache -> dispatch)
      #     -> Metering.emit(cache_hit:) -> return
      module EmbedPipeline
        extend Legion::Logging::Helper

        module_function

        # @param text [String, Array, Hash] caller-supplied text
        # @return [Hash] same shape as Call::Embeddings.generate, plus :cache_hit
        # @raise [Legion::LLM::Errors::RoutingRejected] propagated from selection.
        def call(text:, model: nil, dimensions: nil, task: :document, **)
          result = Call::Embeddings.generate(
            text: normalize_text(text), model: model, dimensions: dimensions, task: task, **
          )
          emit_metering(result: result, cache_hit: result.is_a?(Hash) && result[:cache_hit] == true)
          result
        rescue Legion::LLM::LLMError
          raise
        rescue StandardError => e
          handle_exception(e, level: :warn, operation: 'llm.embed_pipeline.call')
          raise
        end

        # Mirror Call::Embeddings#coerce_text so the value the provider sees (and
        # the digest the cache is keyed on) is exactly what the caller supplied.
        # Call::Embeddings re-normalises internally; the second pass is idempotent.
        def normalize_text(value)
          case value
          when String then value
          when Array
            value.filter_map { |e| e.is_a?(Hash) ? (e[:text] || e[:content]) : e.to_s }
                 .map(&:strip).reject(&:empty?).join("\n")
          when Hash
            (value[:text] || value[:content] || value.values.first).to_s
          else
            value.to_s
          end
        end

        def emit_metering(result:, cache_hit:)
          return unless result.is_a?(Hash) && !result[:error]

          tokens = result[:tokens].to_i
          event = {
            provider:      result[:provider],
            model_id:      result[:model],
            request_type:  'embedding',
            tier:          (result[:tier] || 'direct').to_s,
            input_tokens:  cache_hit ? 0 : tokens,
            output_tokens: 0,
            total_tokens:  cache_hit ? 0 : tokens,
            event_type:    'llm_embedding',
            status:        'success',
            cache_hit:     cache_hit,
            cost_usd:      cache_hit ? 0 : nil,
            caller:        { requested_by: { type: :system, identity: 'legion:internal:embed' } }
          }.compact
          # `cost_usd: nil` is dropped by .compact on the miss path so downstream
          # pricing computes the real cost; on a hit we hard-pin 0.
          event[:cost_usd] = 0 if cache_hit
          Metering.emit(event)
        rescue StandardError => e
          handle_exception(e, level: :warn, operation: 'llm.embed_pipeline.metering')
        end
      end
    end
  end
end
