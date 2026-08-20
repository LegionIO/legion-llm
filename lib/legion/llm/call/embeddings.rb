# frozen_string_literal: true

require 'digest'

require 'legion/logging/helper'
require 'legion/llm/errors'
require 'legion/llm/cache'
require 'legion/llm/router'
require 'legion/llm/router/request_requirements'
require 'legion/llm/inference/request'
require 'legion/llm/inference/routing_session'
require 'legion/llm/call/selection_dispatch'

module Legion
  module LLM
    class EmbeddingUnavailableError < LLMError; end

    module Call
      # SSOT v3 §21 — embeddings on the single execution engine.
      #
      # `generate`/`generate_batch` build a per-call RoutingSession from
      # `RequestRequirements(operation: :embed, required_capabilities: [:embedding])`,
      # select ONE exact lane via `Router.next_lane` (through the session), then
      # dispatch the lane's EXACT callable via `Call::SelectionDispatch` — no
      # `request_lane`, no configured default model/provider/instance, no
      # `Call::Dispatch`. An omitted model is an UNCONSTRAINED selection, never a
      # default. Selection happens BEFORE the cache lookup (§21.2): a hit is only
      # served after a current Selection proves the request has an eligible
      # embedding function. Typed routing errors (RoutingRejected) propagate to
      # the caller — they are never converted to a nil/zero-vector/safe hash.
      module Embeddings
        extend Legion::Logging::Helper

        # Kept for reference/back-compat; the authoritative prefix table lives in
        # settings (`:llm, :embedding, :prefix_registry`) and is model-keyed, so
        # prefixing stays provider-neutral.
        PREFIX_REGISTRY = {
          'nomic-embed-text'  => { document: 'search_document: ', query: 'search_query: ' },
          'mxbai-embed-large' => { query: 'Represent this sentence for searching relevant passages: ' }
        }.freeze

        # Conservative provider-neutral estimate used ONLY for the preselection
        # context bound and for post-selection chunk sizing. The router still
        # authorizes lanes against the offering's authoritative context evidence;
        # this estimate never retroactively authorizes an ineligible lane.
        CHARS_PER_TOKEN = 4
        # Per-chunk conservative token bound (§21.1). A single embedding request
        # is chunked so each chunk targets at most this many tokens; the selected
        # offering's authoritative context can shrink the chunk further.
        EMBED_CHUNK_TARGET_TOKENS = 512
        # Vector post-processing mode recorded in the cache-function identity.
        # Vectors are returned exactly as the provider produced them (no L2
        # normalization, no truncate/pad), so this is a stable constant.
        CACHE_NORMALIZATION = 'none'

        class << self
          # @return [Hash] { vector:, model:, provider:, instance:, dimensions:, tokens:, chunks:, tier:, cache_hit: }
          # @raise [Legion::LLM::Errors::RoutingRejected] when no eligible embedding function / attempts exhausted.
          def generate(text:, model: nil, dimensions: nil, task: :document,
                       provider: nil, instance: nil, request: nil, routing_session: nil, routing_seed: nil, **)
            return not_started_result(model) unless LLM.started?

            coerced = coerce_text(text)
            session = routing_session || build_session(
              texts: [coerced], model: model, provider: provider, instance: instance,
              dimensions: dimensions, request: request, routing_seed: routing_seed
            )
            run_single(session: session, text: coerced, dimensions: dimensions, task: task)
          end

          # @return [Array<Hash>] one entry per input, original order preserved (N -> N).
          # @raise [Legion::LLM::Errors::RoutingRejected] on exhaustion / no eligible function.
          def generate_batch(texts:, model: nil, dimensions: nil, task: :document,
                             provider: nil, instance: nil, request: nil, routing_session: nil, routing_seed: nil, **)
            return texts.map { not_started_result(model) } unless LLM.started?

            coerced = texts.map { |t| coerce_text(t) }
            session = routing_session || build_session(
              texts: coerced, model: model, provider: provider, instance: instance,
              dimensions: dimensions, request: request, routing_seed: routing_seed
            )
            run_batch(session: session, texts: coerced, dimensions: dimensions, task: task)
          end

          private

          # ----------------------------------------------------------------
          # Session construction (§21.1)
          # ----------------------------------------------------------------

          def build_session(texts:, model:, provider:, instance:, dimensions:, request:, routing_seed:)
            req = request || build_request(model: model, provider: provider, instance: instance, routing_seed: routing_seed)
            requirements = Legion::LLM::Router::RequestRequirements.build(
              request:                        req,
              operation:                      :embed,
              required_capabilities:          [:embedding],
              requested_embedding_dimensions: dimensions,
              estimated_input_bound:          preselection_bound(texts),
              required_output_tokens:         0
            )
            Legion::LLM::Inference::RoutingSession.new(request: req, requirements: requirements)
          end

          # A canonical Request carrying a trusted routing context. Prod uses a
          # fresh server seed; specs inject a deterministic seed via routing_seed.
          def build_request(model:, provider:, instance:, routing_seed:)
            routing = { model: model, provider: provider, instance: instance }.compact
            if routing_seed
              Legion::LLM::Inference::Request.build_for_test(routing_seed: routing_seed, messages: [], routing: routing)
            else
              Legion::LLM::Inference::Request.build(messages: [], routing: routing)
            end
          end

          def preselection_bound(texts)
            max_estimate = texts.map { |t| estimate_tokens(t) }.max.to_i
            [max_estimate, EMBED_CHUNK_TARGET_TOKENS].min
          end

          def estimate_tokens(text)
            length = text.to_s.length
            length.zero? ? 0 : (length + CHARS_PER_TOKEN - 1) / CHARS_PER_TOKEN
          end

          # ----------------------------------------------------------------
          # Single-input path (select -> cache -> dispatch -> chunk aggregate)
          # ----------------------------------------------------------------

          def run_single(session:, text:, dimensions:, task:)
            (session.requirements.maximum_attempts + 1).times do
              attempt = session.next_attempt!(snapshot: registry_snapshot)
              chunks = prepare_chunks(text, attempt_context: attempt, task: task)

              key = cache_key(attempt_context: attempt, dimensions: dimensions, task: task, digest_source: text)
              cached = cache_get(key)
              return cached.merge(cache_hit: true) if cached

              result = Legion::LLM::Call::SelectionDispatch.call(
                attempt_context: attempt, arguments: embed_arguments(chunks, dimensions)
              )
              unless result.success?
                terminal = classify_failure(session: session, result: result, attempt: attempt)
                raise terminal if terminal

                next
              end

              vectors = provider_vectors(result.value)
              retry_signal = malformed_retry(session: session, attempt: attempt,
                                             expected: chunks.size, actual: vectors.size)
              if retry_signal
                raise retry_signal unless retry_signal == :retry

                next
              end

              vector = aggregate(vectors, chunks.map(&:length))
              payload = build_single_result(attempt: attempt, vector: vector, dimensions: dimensions,
                                            chunks: chunks.size, tokens: extract_tokens(result.value))
              cache_set(key, payload)
              return payload.merge(cache_hit: false)
            end

            raise routing_rejected(exhausted_rejection(session))
          end

          # ----------------------------------------------------------------
          # Batch path — one exact lane for all N inputs (§21.1/§21.3)
          # ----------------------------------------------------------------

          def run_batch(session:, texts:, dimensions:, task:)
            (session.requirements.maximum_attempts + 1).times do
              attempt = session.next_attempt!(snapshot: registry_snapshot)
              per_item_chunks = texts.map { |t| prepare_chunks(t, attempt_context: attempt, task: task) }
              flat = per_item_chunks.flatten(1)

              result = Legion::LLM::Call::SelectionDispatch.call(
                attempt_context: attempt, arguments: embed_arguments(flat, dimensions)
              )
              unless result.success?
                terminal = classify_failure(session: session, result: result, attempt: attempt)
                raise terminal if terminal

                next
              end

              vectors = provider_vectors(result.value)
              retry_signal = malformed_retry(session: session, attempt: attempt,
                                             expected: flat.size, actual: vectors.size)
              if retry_signal
                raise retry_signal unless retry_signal == :retry

                next
              end

              return reassemble_batch(per_item_chunks: per_item_chunks, flat_vectors: vectors,
                                      attempt: attempt, dimensions: dimensions)
            end

            raise routing_rejected(exhausted_rejection(session))
          end

          def reassemble_batch(per_item_chunks:, flat_vectors:, attempt:, dimensions:)
            cursor = 0
            per_item_chunks.each_with_index.map do |chunks, index|
              slice = flat_vectors[cursor, chunks.size] || []
              cursor += chunks.size
              vector = aggregate(slice, chunks.map(&:length))
              build_batch_entry(attempt: attempt, vector: vector, dimensions: dimensions,
                                chunks: chunks.size, index: index)
            end
          end

          # ----------------------------------------------------------------
          # Failure classification / retry (§21.3)
          # ----------------------------------------------------------------

          # Returns a RoutingRejected to raise (terminal) or nil (retry on the
          # SAME session — the failed provider+instance+model stays consumed).
          def classify_failure(session:, result:, attempt:)
            action = session.classify(dispatch_result: result, attempt_context: attempt)
            return routing_rejected(action.rejection) if action.terminal?

            nil
          end

          # Discard every partial vector from a malformed attempt and retry the
          # whole request on the same session. Returns :retry to continue, a
          # RoutingRejected to raise, or nil when the count is correct.
          def malformed_retry(session:, attempt:, expected:, actual:)
            return nil if actual == expected

            outcome = Legion::Extensions::Llm::Routing::ProviderOutcome.new(
              kind: :malformed_output, reason: "expected #{expected} vectors, got #{actual}"
            )
            failure = Legion::LLM::Call::SelectionDispatch::Result.failure(outcome: outcome)
            terminal = classify_failure(session: session, result: failure, attempt: attempt)
            terminal || :retry
          end

          def embed_arguments(chunks, dimensions)
            text = chunks.one? ? chunks.first : chunks
            args = { text: text }
            args[:dimensions] = dimensions unless dimensions.nil?
            args
          end

          def registry_snapshot
            Legion::Extensions::Llm::Inventory::Registry.snapshot
          end

          def routing_rejected(rejection)
            Legion::LLM::Errors::RoutingRejected.new(rejection: rejection)
          end

          def exhausted_rejection(session)
            Legion::Extensions::Llm::Routing::Rejection.new(
              kind: :attempts_exhausted,
              reason: "embedding attempts exhausted after #{session.attempt_count} attempts",
              inventory_generation: registry_snapshot.generation, candidate_counts: {}, http_status: 503
            )
          end

          # ----------------------------------------------------------------
          # Result shaping
          # ----------------------------------------------------------------

          def build_single_result(attempt:, vector:, dimensions:, chunks:, tokens:)
            raise Legion::LLM::ProviderError, 'embedding provider returned no usable vector' if vector.nil?

            selection = attempt.selection
            {
              vector:     vector,
              model:      selection.model,
              provider:   selection.provider_family,
              instance:   selection.instance_id,
              tier:       attempt.lane.tier,
              dimensions: dimensions || vector.size,
              tokens:     tokens,
              chunks:     chunks
            }
          end

          def build_batch_entry(attempt:, vector:, dimensions:, chunks:, index:)
            raise Legion::LLM::ProviderError, "embedding provider returned no usable vector (index #{index})" if vector.nil?

            selection = attempt.selection
            {
              vector:     vector,
              model:      selection.model,
              provider:   selection.provider_family,
              instance:   selection.instance_id,
              tier:       attempt.lane.tier,
              dimensions: dimensions || vector.size,
              chunks:     chunks,
              index:      index
            }
          end

          # ----------------------------------------------------------------
          # Cache-function identity (§21.2) — NEVER lane/offering/tier/weight/seed
          # ----------------------------------------------------------------

          def cache_key(attempt_context:, dimensions:, task:, digest_source:)
            selection = attempt_context.selection
            lane      = attempt_context.lane
            revision  = revision_or_instance(lane: lane, instance_id: selection.instance_id)
            dims      = dimensions || published_dimension(lane) || 0
            prefix    = prefix_for(selection.model, task).to_s

            identity = {
              provider_family: selection.provider_family.to_s,
              model:           selection.model.to_s,
              model_revision:  revision.to_s,
              dimensions:      dims,
              task:            task.to_s,
              prefix:          prefix,
              normalization:   CACHE_NORMALIZATION,
              input_digest:    Digest::SHA256.hexdigest(digest_source.to_s)
            }
            "#{cache_prefix}:#{selection.provider_family}:#{selection.model}:#{dims}:" \
              "#{Digest::SHA256.hexdigest(Legion::JSON.dump(identity))}"
          end

          # Cross-instance cache reuse is allowed ONLY with authoritative immutable
          # revision evidence; otherwise the exact instance_id scopes the key.
          def revision_or_instance(lane:, instance_id:)
            evidence = lane.model_revision_evidence
            evidence&.known? ? evidence.value : instance_id
          end

          def published_dimension(lane)
            evidence = lane.embedding_dimensions_evidence
            evidence&.known? ? Array(evidence.value).first : nil
          end

          def cache_get(key)
            return nil unless cache_enabled?

            value = Cache.get(key)
            return nil if value.nil?

            symbolize_cached(value)
          end

          def cache_set(key, payload)
            return unless cache_enabled?

            Cache.set(key, cache_payload(payload), ttl: cache_ttl)
          end

          def cache_payload(payload)
            {
              vector:     payload[:vector],
              model:      payload[:model],
              provider:   payload[:provider]&.to_s,
              instance:   payload[:instance],
              tier:       payload[:tier]&.to_s,
              dimensions: payload[:dimensions],
              tokens:     payload[:tokens],
              chunks:     payload[:chunks]
            }.compact
          end

          def symbolize_cached(value)
            hash = value.is_a?(Hash) ? value : {}
            hash = hash.transform_keys { |k| k.respond_to?(:to_sym) ? k.to_sym : k } unless hash.keys.first.is_a?(Symbol)
            hash[:provider] = hash[:provider].to_sym if hash[:provider].is_a?(String)
            hash
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

          # ----------------------------------------------------------------
          # Text prep / prefix / chunking (post-selection, offering-driven)
          # ----------------------------------------------------------------

          def coerce_text(value)
            case value
            when String then value
            when Array
              value.filter_map { |e| e.is_a?(Hash) ? (e[:text] || e[:content]) : e.to_s }
                   .map(&:strip).reject(&:empty?).join("\n")
            when Hash then (value[:text] || value[:content] || value.values.first).to_s
            else value.to_s
            end
          end

          # Chunk AFTER selection using the selected offering's authoritative
          # context contract, then apply the model-specific prefix to each chunk.
          def prepare_chunks(text, attempt_context:, task:)
            model  = attempt_context.selection.model
            prefix = prefix_for(model, task).to_s
            budget = chunk_char_budget(attempt_context)
            room   = budget.nil? ? nil : [budget - prefix.length, 1].max
            chunk_text(text, room).map { |chunk| prefix.empty? ? chunk : "#{prefix}#{chunk}" }
          end

          def chunk_char_budget(attempt_context)
            evidence    = attempt_context.lane.context_evidence
            context_tok = evidence&.known? ? evidence.value.to_i : EMBED_CHUNK_TARGET_TOKENS
            tokens      = [context_tok, EMBED_CHUNK_TARGET_TOKENS].min
            tokens.positive? ? tokens * CHARS_PER_TOKEN : nil
          end

          def prefix_for(model, task)
            registry = Legion::Settings[:llm][:embedding][:prefix_registry]
            model_prefixes = registry[model_base(model)] || registry[model_base(model).to_s] || {}
            model_prefixes[task] || model_prefixes[task.to_s]
          end

          def model_base(model)
            model.to_s.split(':').first
          end

          def chunk_text(text, max_chars)
            return [text] unless max_chars.to_i.positive?
            return [text] if text.length <= max_chars

            chunks = []
            remaining = text.dup
            until remaining.empty?
              chunk, remaining = next_text_chunk(remaining, max_chars)
              chunks << chunk unless chunk.empty?
            end
            chunks
          end

          def next_text_chunk(text, max_chars)
            return [text, ''] if text.length <= max_chars

            slice = text[0, max_chars]
            boundary = chunk_boundary(slice, max_chars)
            chunk = text[0, boundary].strip
            remaining = text[boundary..].to_s.strip
            [chunk.empty? ? text[0, max_chars] : chunk, remaining]
          end

          def chunk_boundary(slice, max_chars)
            candidates = [slice.rindex("\n\n"), slice.rindex("\n"), slice.rindex('. '), slice.rindex(' ')]
            boundary = candidates.compact.max
            return max_chars unless boundary && boundary >= (max_chars * 0.5)

            boundary + 1
          end

          # ----------------------------------------------------------------
          # Provider return handling
          # ----------------------------------------------------------------

          # Normalize the provider return into a flat Array of numeric vectors.
          #
          # 0.8.0 embed artifact (05 S3 / O07): the documented Hash
          # { text:, model:, embedding: Array<Float>, usage: Canonical::Usage }
          # is unwrapped HERE, at the embed consumer boundary — the callables
          # stay raw. +embedding+ is a flat numeric vector for a single input,
          # an Array of them for a batch.
          def provider_vectors(value)
            raw = value.is_a?(Hash) ? value[:embedding] : value
            return [] if raw.nil?
            return [raw] if raw.is_a?(Array) && raw.first.is_a?(Numeric)
            return [value] if raw.is_a?(Array) == false

            raw.map { |vec| vec.is_a?(Array) && vec.first.is_a?(Array) ? vec.first : vec }
          end

          # Weighted average of chunk vectors. For a single vector this returns it
          # unchanged. Never fabricates: returns nil when nothing is usable.
          def aggregate(vectors, weights)
            usable = vectors.each_with_index.filter_map do |vector, index|
              next unless vector.is_a?(Array) && vector.first.is_a?(Numeric)

              [vector, [weights[index].to_i, 1].max]
            end
            return nil if usable.empty?

            dimensions = usable.first.first.size
            usable.select! { |vector, _weight| vector.size == dimensions }
            total_weight = usable.sum { |_vector, weight| weight }.to_f
            Array.new(dimensions) do |index|
              usable.sum { |vector, weight| vector[index].to_f * weight } / total_weight
            end
          end

          # input_tokens from the documented embed artifact's +usage+
          # (Canonical::Usage or a plain hash) — 0 when absent.
          def extract_tokens(value)
            usage = value.is_a?(Hash) ? value[:usage] : nil
            return usage.input_tokens.to_i if usage.respond_to?(:input_tokens)
            return usage[:input_tokens].to_i if usage.is_a?(Hash) && usage.key?(:input_tokens)

            0
          end

          def not_started_result(model)
            { vector: nil, model: model, provider: nil, error: 'LLM not started' }
          end
        end
      end
    end
  end
end
