# frozen_string_literal: true

require 'legion/logging/helper'

require_relative '../call/embeddings'
require_relative '../cache'
require_relative '../content_hash'
require_relative '../metering'

module Legion
  module LLM
    module Inference
      # Slim, governed pipeline for embedding requests (G16/G19): chat-only steps
      # (RAG, tool discovery, GAIA, debate, etc.) do not apply, so embeddings have
      # their own dedicated path:
      #
      #   normalize -> ContentHash -> Cache(model, dims, sha256) lookup
      #     -> on hit: Metering.emit(cost_usd: 0, cache_hit: true) + return
      #     -> on miss: Call::Embeddings.generate -> Metering.emit + Cache.set + return
      #
      # `Legion::LLM.embed` is wired to this pipeline; the public signature stays
      # identical so existing callers keep working. Cache is content-addressed
      # (vectors are deterministic per (model, dims) — a text-only key would
      # collide across embedding spaces). The same SHA-256 utility powers
      # request_content_hash on the audit ledger so records join across systems.
      module EmbedPipeline
        extend Legion::Logging::Helper

        module_function

        # @param text [String, Array, Hash] caller-supplied text
        # @return [Hash] same shape as Call::Embeddings.generate, plus :cache_hit when applicable
        def call(text:, model: nil, provider: nil, instance: nil, dimensions: nil, task: :document)
          normalized = normalize_text(text)
          content_digest = ContentHash.call(normalized)

          cached_key = nil
          cached_value = nil
          if content_digest && cache_lookup_eligible?(model: model)
            cached_key = cache_key(model: model, dimensions: dimensions, digest: content_digest)
            cached_value = Cache.get(cached_key)
          end

          if cached_value
            log.debug("[llm][embed_pipeline] action=cache_hit key=#{cached_key} dims=#{cached_value['dimensions'] || cached_value[:dimensions]}")
            result = symbolize_cached(cached_value)
            emit_metering(result: result, cache_hit: true)
            return result.merge(cache_hit: true)
          end

          result = Call::Embeddings.generate(
            text:       normalized,
            model:      model,
            provider:   provider,
            instance:   instance,
            dimensions: dimensions,
            task:       task
          )

          emit_metering(result: result, cache_hit: false)

          # Persist only when we have a real vector AND an effective cache key
          # (the post-call key resolves the model the provider actually used,
          # which is not always the model the caller passed in).
          if content_digest && cacheable_result?(result)
            persist_key = cache_key(
              model:      result[:model] || model,
              dimensions: result[:dimensions] || dimensions,
              digest:     content_digest
            )
            store_cache_value(persist_key, result)
          end

          result
        rescue StandardError => e
          handle_exception(e, level: :warn, operation: 'llm.embed_pipeline.call')
          { vector: nil, model: model, provider: provider, error: e.message }
        end

        # ------------------------------------------------------------------
        # Helpers
        # ------------------------------------------------------------------

        def normalize_text(value)
          # Mirror Call::Embeddings#coerce_text behaviour, but expose it here so the
          # cache key reflects exactly what the provider sees. Call::Embeddings
          # still re-normalises internally; the second pass is idempotent.
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

        def cache_lookup_eligible?(model:)
          return false unless cache_settings[:enabled] != false
          return false unless model || default_model

          true
        end

        def cache_settings
          Legion::Settings[:llm][:embedding][:cache] || {}
        end

        def cache_key_prefix
          (cache_settings[:key_prefix] || 'llm:embed').to_s
        end

        def cache_ttl
          ttl = cache_settings[:ttl]
          ttl.is_a?(Numeric) && ttl.positive? ? ttl.to_i : Cache::DEFAULT_TTL
        end

        def cache_key(model:, dimensions:, digest:)
          dims = dimensions.to_i
          "#{cache_key_prefix}:#{model}:#{dims}:#{digest}"
        end

        def cacheable_result?(result)
          return false unless result.is_a?(Hash)
          return false if result[:error]

          vector = result[:vector]
          vector.is_a?(Array) && vector.any? && vector.first.is_a?(Numeric)
        end

        def store_cache_value(key, result)
          payload = {
            vector:     result[:vector],
            model:      result[:model],
            provider:   result[:provider]&.to_s,
            dimensions: result[:dimensions],
            tokens:     result[:tokens],
            chunks:     result[:chunks]
          }.compact
          Cache.set(key, payload, ttl: cache_ttl)
        end

        def symbolize_cached(value)
          return value if value.is_a?(Hash) && value.keys.first.is_a?(Symbol)

          symbolized = value.transform_keys { |k| k.respond_to?(:to_sym) ? k.to_sym : k }
          symbolized[:provider] = symbolized[:provider].to_sym if symbolized[:provider].is_a?(String)
          symbolized
        end

        def default_model
          Call::Embeddings.default_model
        rescue StandardError
          nil
        end

        def emit_metering(result:, cache_hit:)
          return unless result.is_a?(Hash) && !result[:error]

          tokens = result[:tokens].to_i
          event = {
            provider:      result[:provider],
            model_id:      result[:model],
            request_type:  'embedding',
            tier:          'direct',
            input_tokens:  cache_hit ? 0 : tokens,
            output_tokens: 0,
            total_tokens:  cache_hit ? 0 : tokens,
            event_type:    'llm_embedding',
            status:        'success',
            cache_hit:     cache_hit,
            cost_usd:      cache_hit ? 0 : nil,
            caller:        { requested_by: { type: :system, identity: 'legion:internal:embed' } }
          }.compact
          # `cost_usd: nil` removed by .compact for the miss path so downstream
          # pricing logic can compute the actual cost; on a hit we hard-pin 0.
          event[:cost_usd] = 0 if cache_hit
          Metering.emit(event)
        rescue StandardError => e
          handle_exception(e, level: :warn, operation: 'llm.embed_pipeline.metering')
        end
      end
    end
  end
end
