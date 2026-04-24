# frozen_string_literal: true

# Monkey-patch RubyLLM's Bedrock provider to support embeddings via
# Amazon Titan (amazon.titan-embed-text-v1 and v2) and Cohere Embed
# (cohere.embed-english-v3 / cohere.embed-multilingual-v3).
#
# Without this patch, `RubyLLM::Providers::Bedrock` exposes no
# `render_embedding_payload` method, so the discovery probe
# (`klass.instance_method(:render_embedding_payload)`) raises NameError
# and Bedrock is silently excluded from the embedding fallback chain.
#
# Companion piece to `call/bedrock_auth.rb` — both use the same
# bearer-or-SigV4 `signed_post` path and live here (not in lex-bedrock)
# because lex-bedrock wraps `aws-sdk-bedrockruntime`, not RubyLLM.
#
# ─── Upstream tracking ────────────────────────────────────────────
# This is a deprecation-scheduled shim. The methods below are the
# kind of thing that eventually belongs in the underlying ruby_llm
# library's Bedrock provider. Remove this file once upstream ships
# equivalent support. The short-circuit below renders the patch
# inert when `render_embedding_payload` is defined natively, so an
# accidental double-load after an upstream bump is safe.
# ───────────────────────────────────────────────────────────────────
#
# Titan v2 request shape:
#   POST /model/amazon.titan-embed-text-v2:0/invoke
#   { "inputText": "...", "dimensions": 1024, "normalize": true }
#   => { "embedding": [...], "inputTextTokenCount": N }
#
# Cohere Embed request shape:
#   POST /model/cohere.embed-english-v3/invoke
#   { "texts": ["..."], "input_type": "search_document" }
#   => { "embeddings": [[...]], ... }

require 'ruby_llm'
require_relative 'bedrock_auth'

if RubyLLM::Providers::Bedrock.method_defined?(:render_embedding_payload)
  # Native support landed upstream — patch is inert.
  Legion::Logging.logger.info('[llm][bedrock_embeddings] native ruby_llm embedding support detected — skipping patch')
else

  module RubyLLM
    module Providers
      class Bedrock
        # Embeddings methods for AWS Bedrock via InvokeModel.
        #
        # Public methods are instance methods (not `module_function`) so the
        # `include Embeddings` at the end of the class body properly overrides
        # `Provider#embed` via Ruby's method-resolution order.
        module Embeddings
          TITAN_V2_PREFIX = 'amazon.titan-embed-text-v2'
          TITAN_V1_PREFIX = 'amazon.titan-embed-text-v1'
          COHERE_PREFIX   = 'cohere.embed'

          TITAN_ALLOWED_DIMENSIONS = [256, 512, 1024].freeze
          TITAN_MAX_INPUT_BYTES    = 45_000   # ~8k tokens; Titan rejects larger with 400 (and still bills)
          COHERE_MAX_INPUT_BYTES   = 8_192    # Cohere Embed v3 per-text byte budget
          COHERE_MAX_TEXTS         = 96       # Cohere Embed v3 batch limit
          # Bedrock model IDs use only alphanumerics, `.`, `-`, and `:` (e.g.
          # `amazon.titan-embed-text-v2:0`, `cohere.embed-english-v3`,
          # `us.anthropic.claude-sonnet-4-6-v1`). Slashes and `..` are rejected
          # to block path-injection into the `/model/<id>/invoke` URL.
          MODEL_ID_PATTERN         = /\A[a-zA-Z0-9.\-:]+\z/

          # @param model [String, Symbol] Bedrock model id
          # @return [String] InvokeModel URL path
          # @raise [RubyLLM::Error] if model id contains unsafe characters
          def embedding_url(model:)
            raise RubyLLM::Error.new(nil, "Invalid Bedrock model id: #{model.inspect}") \
              unless model.to_s.match?(MODEL_ID_PATTERN)

            "/model/#{model}/invoke"
          end

          # @param text [String, Array<String>]
          # @param model [String] Bedrock embedding model id
          # @param dimensions [Integer, nil] Titan v2 only; one of {256, 512, 1024}
          # @return [Hash] JSON-serializable request payload
          # @raise [RubyLLM::Error] on unsupported model, oversize input, or invalid dimensions
          def render_embedding_payload(text, model:, dimensions:)
            model_str = model.to_s

            if model_str.start_with?(TITAN_V2_PREFIX)
              titan_v2_payload(text, dimensions: dimensions)
            elsif model_str.start_with?(TITAN_V1_PREFIX)
              titan_v1_payload(text)
            elsif model_str.start_with?(COHERE_PREFIX)
              cohere_payload(text)
            else
              raise RubyLLM::Error.new(
                nil,
                "Bedrock model '#{model}' is not supported for embeddings. " \
                'Supported prefixes: amazon.titan-embed-text-v1, ' \
                'amazon.titan-embed-text-v2, cohere.embed-*.'
              )
            end
          end

          # @param response [Faraday::Response]
          # @param model [String]
          # @param text [String, Array<String>] original input (used for shape decisions)
          # @return [RubyLLM::Embedding]
          # @raise [RubyLLM::Error] if the response carried no vector
          def parse_embedding_response(response, model:, text:)
            body = response.body
            body = try_parse_json(body) if body.is_a?(String)

            vectors =
              if model.to_s.start_with?(COHERE_PREFIX)
                Array(body['embeddings'])
              else
                # Titan single-text response: the single vector lives in :embedding.
                # Batch callers are handled in `embed` via iteration.
                [body['embedding']].compact
              end

            raise RubyLLM::Error.new(response, "Empty embedding response for model #{model}") if vectors.empty?

            vectors = vectors.first if vectors.length == 1 && !text.is_a?(Array)
            input_tokens = body['inputTextTokenCount'] ||
                           body.dig('meta', 'billed_units', 'input_tokens') ||
                           0

            RubyLLM::Embedding.new(vectors: vectors, model: model, input_tokens: input_tokens)
          end

          # Override the base `embed` method so signing headers are applied.
          #
          # The parent `Provider#embed` calls `@connection.post(url, payload)` directly,
          # which would skip both bearer-token and SigV4 auth for Bedrock. We go through
          # `invoke_embedding`, which mirrors `signed_post` but parses responses with
          # `parse_embedding_response` (not `parse_completion_response`).
          #
          # Titan accepts a single text per invocation. When an Array is passed to a
          # Titan model, we iterate via `embed_titan_batch`, which traps per-element
          # failures so one 429 mid-batch does not lose preceding successes.
          #
          # @param text [String, Array<String>]
          # @param model [String]
          # @param dimensions [Integer, nil]
          # @return [RubyLLM::Embedding]
          def embed(text, model:, dimensions:)
            return embed_titan_batch(text, model: model, dimensions: dimensions) \
              if text.is_a?(Array) && !model.to_s.start_with?(COHERE_PREFIX)

            payload  = render_embedding_payload(text, model: model, dimensions: dimensions)
            url      = embedding_url(model: model)
            response = invoke_embedding(url, payload)
            parse_embedding_response(response, model: model, text: text)
          end

          private

          def titan_v2_payload(text, dimensions:)
            raise RubyLLM::Error.new(nil, 'Titan v2 embeddings accept a single string per invocation.') \
              if text.is_a?(Array)

            enforce_input_size!(text, TITAN_MAX_INPUT_BYTES, 'Titan v2')

            payload = { inputText: text.to_s, normalize: true }
            dim     = dimensions&.to_i
            if dim
              unless TITAN_ALLOWED_DIMENSIONS.include?(dim)
                raise RubyLLM::Error.new(
                  nil,
                  "Titan v2 dimensions must be one of #{TITAN_ALLOWED_DIMENSIONS.inspect}, got #{dim}"
                )
              end
              payload[:dimensions] = dim
            end
            payload
          end

          def titan_v1_payload(text)
            raise RubyLLM::Error.new(nil, 'Titan v1 embeddings accept a single string per invocation.') \
              if text.is_a?(Array)

            enforce_input_size!(text, TITAN_MAX_INPUT_BYTES, 'Titan v1')
            { inputText: text.to_s }
          end

          def cohere_payload(text)
            texts = Array(text).map(&:to_s)
            raise RubyLLM::Error.new(nil, "Cohere Embed batch size #{texts.size} exceeds max #{COHERE_MAX_TEXTS}") \
              if texts.size > COHERE_MAX_TEXTS

            texts.each { |t| enforce_input_size!(t, COHERE_MAX_INPUT_BYTES, 'Cohere Embed') }

            { texts: texts, input_type: 'search_document' }
          end

          def enforce_input_size!(text, max_bytes, model_name)
            bytes = text.to_s.bytesize
            return if bytes <= max_bytes

            raise RubyLLM::Error.new(
              nil,
              "#{model_name} input too large: #{bytes} bytes exceeds max #{max_bytes}. " \
              'Caller must chunk before embedding.'
            )
          end

          # Mirror of `signed_post` for embeddings: pre-serializes the body so the
          # SigV4 signature matches the bytes Faraday actually sends. `@connection.post`
          # is `RubyLLM::Connection#post(url, payload)` which requires both args, so we
          # pass `payload` to satisfy the arity but override `req.body = body` in the
          # block — the block runs after middleware, so the pre-serialized bytes win
          # over whatever JSON middleware would have produced.
          def invoke_embedding(url, payload)
            body    = JSON.generate(payload)
            headers = sign_headers('POST', url, body)

            @connection.post(url, payload) do |req|
              req.headers.merge!(headers)
              req.body = body
            end
          end

          # Per-item trap-and-continue for Titan batch. Returns a combined Embedding
          # whose `vectors` is an Array of [Float] per input index, with `nil` entries
          # for failed slots. Token count aggregates successful calls.
          #
          # Raises only when every element failed — otherwise logs failures via
          # `RubyLLM.logger` and returns partial results so callers keep the paid-for
          # vectors. Idiomatic for this file because we are inside the RubyLLM
          # namespace; Legion-side batch orchestration lives in
          # `Legion::LLM::Call::Embeddings.generate_batch`.
          def embed_titan_batch(texts, model:, dimensions:)
            vectors     = []
            token_total = 0
            failures    = []

            texts.each_with_index do |text, idx|
              single = embed(text.to_s, model: model, dimensions: dimensions)
              vectors << Array(single.vectors).first
              token_total += single.input_tokens.to_i
            rescue StandardError => e
              vectors << nil
              failures << { index: idx, error: e.class.name, message: e.message }
            end

            unless failures.empty?
              RubyLLM.logger.warn(
                '[bedrock_embeddings] Titan batch partial failure: ' \
                "#{failures.size}/#{texts.size} model=#{model}"
              )
              failures.each do |f|
                RubyLLM.logger.debug(
                  "[bedrock_embeddings] batch item index=#{f[:index]} error=#{f[:error]} message=#{f[:message]}"
                )
              end
            end

            if failures.size == texts.size
              raise RubyLLM::Error.new(
                nil,
                "All #{texts.size} Titan batch items failed. First error: #{failures.first[:message]}"
              )
            end

            RubyLLM::Embedding.new(vectors: vectors, model: model, input_tokens: token_total)
          end
        end

        include Embeddings
      end
    end
  end
end
