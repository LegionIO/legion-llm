# frozen_string_literal: true

require 'digest'

require 'legion/logging/helper'
require 'legion/llm/errors'
require 'legion/llm/cache'
require 'legion/llm/router'
require 'legion/llm/inference/request'
require 'legion/llm/call/selection_dispatch'

module Legion
  module LLM
    class EmbeddingUnavailableError < LLMError; end

    module Call
      # The Router is the sole embedding selector. Select before consulting the
      # function-identity cache, and retry malformed attempts through the same
      # typed routing policy as provider failures.
      module Embeddings
        extend Legion::Logging::Helper

        # The authoritative, provider-neutral prefix policy lives in settings.
        PREFIX_REGISTRY = {
          'nomic-embed-text'  => { document: 'search_document: ', query: 'search_query: ' },
          'mxbai-embed-large' => { query: 'Represent this sentence for searching relevant passages: ' }
        }.freeze
        CHARS_PER_TOKEN = 4
        EMBED_CHUNK_TARGET_TOKENS = 512
        CACHE_NORMALIZATION = 'none'

        class << self
          def generate(text:, model: nil, dimensions: nil, task: :document,
                       provider: nil, instance: nil, request: nil, router: nil, routing_seed: nil, **)
            return not_started_result(model: model) unless LLM.started?

            task = embedding_task(task: task)
            rtr = router || build_router(model: model, provider: provider, instance: instance,
                                         dimensions: dimensions, request: request, routing_seed: routing_seed)
            run_single(router: rtr, text: coerce_text(value: text),
                       dimensions: rtr.requested_embedding_dimensions || dimensions, task: task)
          end

          def generate_batch(texts:, model: nil, dimensions: nil, task: :document,
                             provider: nil, instance: nil, request: nil, router: nil, routing_seed: nil, **)
            return texts.map { not_started_result(model: model) } unless LLM.started?

            task = embedding_task(task: task)
            rtr = router || build_router(model: model, provider: provider, instance: instance,
                                         dimensions: dimensions, request: request, routing_seed: routing_seed)
            run_batch(router: rtr, texts: texts.map { |text| coerce_text(value: text) },
                      dimensions: rtr.requested_embedding_dimensions || dimensions, task: task)
          end

          private

          def embedding_task(task:, **)
            return task.to_sym if %w[document query].include?(task.to_s)

            raise ArgumentError, 'embedding task must be document or query'
          end

          def build_router(model:, provider:, instance:, dimensions:, request:, routing_seed:, **)
            req = request || build_request(model: model, provider: provider, instance: instance,
                                           dimensions: dimensions, routing_seed: routing_seed)
            Legion::LLM::Router.new(request: req, operation: :embed, body_model: model)
          end

          def build_request(model:, provider:, instance:, dimensions:, routing_seed:, **)
            routing = { model: model, provider: provider, instance: instance }.compact
            extra = dimensions ? { embedding_dimensions: dimensions } : {}
            if routing_seed
              Legion::LLM::Inference::Request.build_for_test(routing_seed: routing_seed, messages: [],
                                                             routing: routing, extra: extra)
            else
              Legion::LLM::Inference::Request.build(messages: [], routing: routing, extra: extra)
            end
          end

          def run_single(router:, text:, dimensions:, task:, **)
            router.maximum_attempts.times do
              attempt = router.next_attempt!
              chunks = prepare_chunks(text: text, attempt_context: attempt, task: task)
              key = cache_key(attempt_context: attempt, dimensions: dimensions, task: task, digest_source: text)
              cached = cache_get(key: key, attempt: attempt, dimensions: dimensions, task: task, chunks: chunks.size)
              return cached.merge(cache_hit: true) if cached

              result = Legion::LLM::Call::SelectionDispatch.call(
                attempt_context: attempt, arguments: embed_arguments(chunks: chunks, dimensions: dimensions)
              )
              unless result.success?
                terminal = classify_failure(router: router, result: result, attempt: attempt)
                raise terminal if terminal

                next
              end

              vectors = provider_vectors(value: result.value)
              reason = vectors_error(vectors: vectors, expected: chunks.size, dimensions: dimensions)
              vector = aggregate(vectors: vectors, weights: chunks.map(&:length)) unless reason
              reason ||= 'aggregated embedding is not a finite nonzero vector' unless valid_vector?(vector: vector)
              if reason
                terminal = malformed_retry(router: router, attempt: attempt, reason: reason)
                raise terminal if terminal

                next
              end

              payload = build_result(attempt: attempt, vector: vector, task: task, chunks: chunks.size)
              payload[:tokens] = extract_tokens(value: result.value)
              cache_set(key: key, payload: payload)
              return payload.merge(cache_hit: false)
            end

            raise routing_rejected(rejection: exhausted_rejection(router: router))
          end

          def run_batch(router:, texts:, dimensions:, task:, **)
            router.maximum_attempts.times do
              attempt = router.next_attempt!
              per_item_chunks = texts.map { |text| prepare_chunks(text: text, attempt_context: attempt, task: task) }
              flat = per_item_chunks.flatten(1)
              result = Legion::LLM::Call::SelectionDispatch.call(
                attempt_context: attempt, arguments: embed_arguments(chunks: flat, dimensions: dimensions)
              )
              unless result.success?
                terminal = classify_failure(router: router, result: result, attempt: attempt)
                raise terminal if terminal

                next
              end

              vectors = provider_vectors(value: result.value)
              reason = vectors_error(vectors: vectors, expected: flat.size, dimensions: dimensions)
              entries = reassemble_batch(per_item_chunks: per_item_chunks, flat_vectors: vectors, attempt: attempt, task: task) unless reason
              reason = 'aggregated embedding is not a finite nonzero vector' if entries&.any? { |entry| !valid_vector?(vector: entry[:vector]) }
              if reason
                terminal = malformed_retry(router: router, attempt: attempt, reason: reason)
                raise terminal if terminal

                next
              end

              return entries
            end

            raise routing_rejected(rejection: exhausted_rejection(router: router))
          end

          def reassemble_batch(per_item_chunks:, flat_vectors:, attempt:, task:, **)
            cursor = 0
            per_item_chunks.each_with_index.map do |chunks, index|
              slice = flat_vectors[cursor, chunks.size]
              cursor += chunks.size
              vector = aggregate(vectors: slice, weights: chunks.map(&:length))
              build_result(attempt: attempt, vector: vector, task: task, chunks: chunks.size).merge(index: index)
            end
          end

          def classify_failure(router:, result:, attempt:, **)
            action = router.classify(dispatch_result: result, attempt_context: attempt)
            return routing_rejected(rejection: action.rejection) if action.terminal?

            nil
          end

          # Classify a complete malformed attempt, never keep a subset of chunks.
          def malformed_retry(router:, attempt:, reason:, **)
            outcome = Legion::Extensions::Llm::Routing::ProviderOutcome.new(kind: :malformed_output, reason: reason)
            failure = Legion::LLM::Call::SelectionDispatch::Result.failure(outcome: outcome)
            classify_failure(router: router, result: failure, attempt: attempt)
          end

          def embed_arguments(chunks:, dimensions:, **)
            args = { text: chunks.one? ? chunks.first : chunks }
            args[:dimensions] = dimensions unless dimensions.nil?
            args
          end

          def routing_rejected(rejection:, **)
            Legion::LLM::Errors::RoutingRejected.new(rejection: rejection)
          end

          def exhausted_rejection(router:, **)
            used = router.maximum_attempts - router.attempts_remaining
            Legion::Extensions::Llm::Routing::Rejection.new(
              kind: :attempts_exhausted,
              reason: "embedding attempts exhausted after #{used} attempts",
              inventory_generation: Legion::Extensions::Llm::Inventory::Registry.snapshot.generation,
              candidate_counts: {}, http_status: 503
            )
          end

          def build_result(attempt:, vector:, task:, chunks:, **)
            selection = attempt.selection
            {
              vector: vector, model: selection.model, provider: selection.provider_family,
              instance: selection.instance_id, tier: attempt.lane.tier, dimensions: vector.size, chunks: chunks,
              embedding_provenance: embedding_provenance(attempt: attempt, dimensions: vector.size, task: task)
            }
          end

          # A model's document/query prefix PAIR defines one space; task itself
          # only scopes the input cache. Unknown revisions isolate exact instances.
          def embedding_identity(attempt:, dimensions:, **)
            selection = attempt.selection
            evidence = attempt.lane.model_revision_evidence
            revision = evidence.value.to_s if evidence&.known? && !evidence.value.to_s.empty?
            {
              provider: selection.provider_family.to_s, model: selection.model.to_s,
              model_revision: revision, identity_source: revision ? 'revision' : 'instance',
              instance: revision ? nil : selection.instance_id.to_s,
              dimensions: dimensions,
              prefixes: { document: prefix_for(model: selection.model, task: :document).to_s,
                          query:    prefix_for(model: selection.model, task: :query).to_s },
              normalization: CACHE_NORMALIZATION
            }
          end

          def embedding_provenance(attempt:, dimensions:, task:, **)
            identity = embedding_identity(attempt: attempt, dimensions: dimensions)
            identity.merge(space_id: Digest::SHA256.hexdigest(Legion::JSON.dump(identity)),
                           instance: attempt.selection.instance_id.to_s, task: task.to_s)
          end

          def cache_key(attempt_context:, dimensions:, task:, digest_source:, **)
            selection = attempt_context.selection
            evidence = attempt_context.lane.embedding_dimensions_evidence
            dims = dimensions || (Array(evidence.value).first if evidence&.known?) || 0
            identity = embedding_identity(attempt: attempt_context, dimensions: dims)
            identity[:task] = task.to_s
            identity[:input_digest] = Digest::SHA256.hexdigest(digest_source.to_s)
            "#{cache_prefix}:#{selection.provider_family}:#{selection.model}:#{dims}:" \
              "#{Digest::SHA256.hexdigest(Legion::JSON.dump(identity))}"
          end

          def cache_get(key:, attempt:, dimensions:, task:, chunks:, **)
            return nil unless cache_enabled?

            value = Cache.get(key)
            return nil unless value.is_a?(Hash)

            cached = value.transform_keys { |field| field.is_a?(String) ? field.to_sym : field }
            return nil unless valid_vector?(vector: cached[:vector], dimensions: dimensions)
            return nil if cached[:dimensions] && cached[:dimensions] != cached[:vector].size

            payload = build_result(attempt: attempt, vector: cached[:vector], task: task, chunks: chunks)
            previous = cached[:embedding_provenance]
            return nil unless previous.is_a?(Hash)

            previous = previous.transform_keys { |field| field.is_a?(String) ? field.to_sym : field }
            return nil unless previous[:instance].is_a?(String) && !previous[:instance].empty?
            return nil unless previous[:prefixes].is_a?(Hash)

            previous[:prefixes] = previous[:prefixes].transform_keys { |field| field.is_a?(String) ? field.to_sym : field }
            expected = payload[:embedding_provenance]
            compatible = expected.all? do |field, value|
              (field == :instance && expected[:identity_source] == 'revision') || previous[field] == value
            end
            return nil unless compatible

            payload[:tokens] = cached[:tokens] || 0
            payload
          end

          def cache_set(key:, payload:, **)
            return unless cache_enabled?

            Cache.set(key, payload.merge(provider: payload[:provider].to_s, tier: payload[:tier]&.to_s), ttl: cache_ttl)
          end

          def cache_enabled?
            cache_settings[:enabled] != false
          end

          def cache_settings
            Legion::Settings[:llm][:embedding][:cache] || {}
          end

          def cache_prefix
            (cache_settings[:key_prefix] || 'llm:embed').to_s
          end

          def cache_ttl
            ttl = cache_settings[:ttl]
            ttl.is_a?(Numeric) && ttl.positive? ? ttl.to_i : Cache::DEFAULT_TTL
          end

          def coerce_text(value:, **)
            case value
            when String then value
            when Array
              value.filter_map { |entry| entry.is_a?(Hash) ? (entry[:text] || entry[:content]) : entry.to_s }
                   .map(&:strip).reject(&:empty?).join("\n")
            when Hash then (value[:text] || value[:content] || value.values.first).to_s
            else value.to_s
            end
          end

          def prepare_chunks(text:, attempt_context:, task:, **)
            prefix = prefix_for(model: attempt_context.selection.model, task: task).to_s
            budget = chunk_char_budget(attempt_context: attempt_context)
            room = budget.nil? ? nil : [budget - prefix.length, 1].max
            chunk_text(text: text, max_chars: room).map { |chunk| prefix.empty? ? chunk : "#{prefix}#{chunk}" }
          end

          def chunk_char_budget(attempt_context:, **)
            evidence = attempt_context.lane.context_evidence
            context_tokens = evidence&.known? ? evidence.value.to_i : EMBED_CHUNK_TARGET_TOKENS
            tokens = [context_tokens, EMBED_CHUNK_TARGET_TOKENS].min
            tokens.positive? ? tokens * CHARS_PER_TOKEN : nil
          end

          def prefix_for(model:, task:, **)
            registry = Legion::Settings[:llm][:embedding][:prefix_registry]
            base = model.to_s.split(':').first
            model_prefixes = registry[base] || registry[base.to_sym] || {}
            model_prefixes[task] || model_prefixes[task.to_s]
          end

          def chunk_text(text:, max_chars:, **)
            return [text] unless max_chars.to_i.positive?
            return [text] if text.length <= max_chars

            chunks = []
            remaining = text.dup
            until remaining.empty?
              chunk, remaining = next_text_chunk(text: remaining, max_chars: max_chars)
              chunks << chunk unless chunk.empty?
            end
            chunks
          end

          def next_text_chunk(text:, max_chars:, **)
            return [text, ''] if text.length <= max_chars

            slice = text[0, max_chars]
            boundary = chunk_boundary(slice: slice, max_chars: max_chars)
            chunk = text[0, boundary].strip
            remaining = text[boundary..].to_s.strip
            [chunk.empty? ? text[0, max_chars] : chunk, remaining]
          end

          def chunk_boundary(slice:, max_chars:, **)
            candidates = [slice.rindex("\n\n"), slice.rindex("\n"), slice.rindex('. '), slice.rindex(' ')]
            boundary = candidates.compact.max
            return max_chars unless boundary && boundary >= (max_chars * 0.5)

            boundary + 1
          end

          # Canonical provider artifacts use :embedding; LexLLMAdapter's defined
          # callable contract uses :result. Do not guess at arbitrary objects or
          # unwrap nested vectors (which would silently discard malformed data).
          def provider_vectors(value:, **)
            raw = if value.is_a?(Hash)
                    value.key?(:embedding) ? value[:embedding] : value[:result]
                  else
                    value
                  end
            return [] unless raw.is_a?(Array)
            return [raw] if raw.first.is_a?(Numeric)

            raw
          end

          def valid_vector?(vector:, dimensions: nil, **)
            return false unless vector.is_a?(Array) && !vector.empty?
            return false if dimensions && vector.size != dimensions
            return false unless vector.all? { |number| number.is_a?(Numeric) && number.real? && number.finite? }

            vector.any? { |number| !number.zero? }
          end

          def vectors_error(vectors:, expected:, dimensions:, **)
            return "expected #{expected} vectors, got #{vectors.size}" unless vectors.size == expected
            return 'embedding contains an invalid, nonfinite, or zero vector' unless vectors.all? { |vector| valid_vector?(vector: vector) }

            size = dimensions || vectors.first&.size
            return 'embedding dimensions do not match across the complete request' unless vectors.all? { |vector| vector.size == size }

            nil
          end

          # All chunks have already been validated together. Never drop, truncate,
          # pad, or normalize vectors. One chunk preserves the provider values.
          def aggregate(vectors:, weights:, **)
            return vectors.first if vectors.one?

            total_weight = weights.sum { |weight| [weight, 1].max }.to_f
            Array.new(vectors.first.size) do |index|
              vectors.each_with_index.sum { |vector, chunk| vector[index] * ([weights[chunk], 1].max / total_weight) }
            end
          end

          def extract_tokens(value:, **)
            usage = value.is_a?(Hash) ? value[:usage] : nil
            return usage.input_tokens.to_i if usage.is_a?(Legion::Extensions::Llm::Canonical::Usage)
            return usage[:input_tokens].to_i if usage.is_a?(Hash) && usage.key?(:input_tokens)

            0
          end

          def not_started_result(model:, **)
            { vector: nil, model: model, provider: nil, error: 'LLM not started' }
          end
        end
      end
    end
  end
end
