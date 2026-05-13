# frozen_string_literal: true

require 'legion/logging/helper'

module Legion
  module LLM
    class EmbeddingUnavailableError < LLMError; end

    module Call
      module Embeddings
        extend Legion::Logging::Helper

        PREFIX_REGISTRY = {
          'nomic-embed-text'  => { document: 'search_document: ', query: 'search_query: ' },
          'mxbai-embed-large' => { query: 'Represent this sentence for searching relevant passages: ' }
        }.freeze

        class << self
          def generate(text:, model: nil, provider: nil, instance: nil,
                       dimensions: nil, task: :document)
            return not_started_result(model, provider) unless LLM.started?

            provider ||= resolve_provider
            return unavailable_result(model, provider) unless provider

            model ||= resolve_model
            text = coerce_text(text)
            text_length = text.length
            prepared_texts = prepare_embedding_texts(text, provider: provider, model: model, task: task)
            dispatch_text = prepared_texts.one? ? prepared_texts.first : prepared_texts

            log.info("[llm][embed] action=generate provider=#{provider} instance=#{instance || 'default'} " \
                     "model=#{model} task=#{task} text_chars=#{text_length} chunks=#{prepared_texts.size}")

            started_at = ::Process.clock_gettime(::Process::CLOCK_MONOTONIC)
            response = Dispatch.call(
              provider:   provider,
              instance:   instance,
              capability: :embed,
              model:      model,
              text:       dispatch_text,
              dimensions: dimensions
            )
            elapsed = ((::Process.clock_gettime(::Process::CLOCK_MONOTONIC) - started_at) * 1000).round(1)

            vector = if prepared_texts.size > 1
                       aggregate_vectors(response[:result], weights: prepared_texts.map(&:length), model: model, provider: provider)
                     else
                       normalize_vector(response[:result])
                     end
            vector = enforce_dimensions(vector) if enforce_dimension?
            tokens = extract_tokens(response)

            log.info("[llm][embed] action=generate.complete provider=#{provider} instance=#{instance || 'default'} " \
                     "model=#{model} dimensions=#{vector&.size || 0} tokens=#{tokens} chunks=#{prepared_texts.size} duration_ms=#{elapsed}")

            {
              vector:     vector,
              model:      model,
              provider:   provider,
              dimensions: vector&.size || 0,
              tokens:     tokens,
              chunks:     prepared_texts.size
            }
          rescue StandardError => e
            handle_exception(e, level: :warn, operation: 'llm.embeddings.generate')
            { vector: nil, model: model, provider: provider, error: e.message }
          end

          def generate_batch(texts:, model: nil, provider: nil, instance: nil,
                             dimensions: nil, task: :document)
            return texts.map { { vector: nil, error: 'LLM not started' } } unless LLM.started?

            provider ||= resolve_provider
            model ||= resolve_model

            log.info("[llm][embed] action=generate_batch provider=#{provider} instance=#{instance || 'default'} " \
                     "model=#{model} count=#{texts.size} task=#{task}")

            raw_texts = texts.map { |t| coerce_text(t) }
            prepared_texts = raw_texts.map { |t| prepare_embedding_texts(t, provider: provider, model: model, task: task) }
            if prepared_texts.any? { |chunks| chunks.size > 1 }
              return generate_chunked_batch(
                raw_texts,
                model:      model,
                provider:   provider,
                instance:   instance,
                dimensions: dimensions,
                task:       task
              )
            end

            texts = prepared_texts.map(&:first)

            started_at = ::Process.clock_gettime(::Process::CLOCK_MONOTONIC)
            response = Dispatch.call(
              provider:   provider,
              instance:   instance,
              capability: :embed,
              model:      model,
              text:       texts,
              dimensions: dimensions
            )
            elapsed = ((::Process.clock_gettime(::Process::CLOCK_MONOTONIC) - started_at) * 1000).round(1)

            result = normalize_batch(response[:result], model, provider)

            log.info("[llm][embed] action=generate_batch.complete provider=#{provider} " \
                     "model=#{model} count=#{result.size} duration_ms=#{elapsed}")

            result
          rescue StandardError => e
            handle_exception(e, level: :warn, operation: 'llm.embeddings.generate_batch')
            texts.map { { vector: nil, model: model, provider: provider, error: e.message } }
          end

          def default_model
            resolve_model
          end

          private

          def resolve_provider
            LLM.embedding_provider ||
              Legion::LLM::Settings.value(:embedding, :provider)&.to_sym
          end

          def resolve_model
            LLM.embedding_model ||
              Legion::LLM::Settings.value(:embedding, :default_model)
          end

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

          def apply_prefix(text, model:, task:)
            prefix = prefix_for(model, task)
            prefix ? "#{prefix}#{text}" : text
          end

          def prepare_embedding_texts(text, provider:, model:, task:)
            prefix = prefix_for(model, task).to_s
            chunks = chunk_text(text, embedding_chunk_chars(provider: provider, model: model, prefix: prefix))
            chunks.map { |chunk| prefix.empty? ? chunk : "#{prefix}#{chunk}" }
          end

          def prefix_for(model, task)
            registry = Legion::LLM::Settings.value(:embedding, :prefix_registry, default: PREFIX_REGISTRY)
            model_prefixes = Legion::LLM::Settings.config_value(registry, model_base(model), {})
            Legion::LLM::Settings.config_value(model_prefixes, task)
          end

          def embedding_chunk_chars(provider:, model:, prefix:)
            return nil unless provider.to_s == 'ollama'

            embedding = Legion::LLM::Settings.value(:embedding, default: {})
            context_chars = Legion::LLM::Settings.config_value(embedding, :ollama_context_chars, {})
            limit = Legion::LLM::Settings.config_value(context_chars, model.to_s) ||
                    Legion::LLM::Settings.config_value(context_chars, model_base(model)) ||
                    Legion::LLM::Settings.config_value(embedding, :ollama_default_context_chars)
            limit = limit.to_i
            return nil unless limit.positive?

            [limit - prefix.length, 1].max
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

          def model_base(model)
            model.to_s.split(':').first
          end

          def normalize_vector(result)
            return nil if result.nil?
            return result if result.is_a?(Array) && result.first.is_a?(Numeric)
            return result.first if result.is_a?(Array) && result.first.is_a?(Array)

            result
          end

          def normalize_batch(result, model, provider)
            vectors = result.is_a?(Array) ? result : [result]
            vectors.each_with_index.map do |vec, i|
              v = vec.is_a?(Array) && vec.first.is_a?(Array) ? vec.first : vec
              v = enforce_dimensions(v) if enforce_dimension? && v.is_a?(Array)
              { vector: v, model: model, provider: provider,
                dimensions: v.is_a?(Array) ? v.size : 0, index: i }
            end
          end

          def aggregate_vectors(result, weights:, model:, provider:)
            vectors = normalize_batch(result, model, provider).map { |entry| entry[:vector] }
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

          def generate_chunked_batch(texts, model:, provider:, instance:, dimensions:, task:)
            log.info("[llm][embed] action=generate_batch.chunked provider=#{provider} instance=#{instance || 'default'} " \
                     "model=#{model} count=#{texts.size}")

            texts.each_with_index.map do |text, index|
              generate(
                text:       text,
                model:      model,
                provider:   provider,
                instance:   instance,
                dimensions: dimensions,
                task:       task
              ).merge(index: index)
            end
          end

          def enforce_dimension?
            Legion::LLM::Settings.value(:embedding, :enforce_dimension) != false
          end

          def enforce_dimensions(vector)
            return vector unless vector.is_a?(Array)

            dim = Legion::LLM::Settings.value(:embedding, :dimension) || 1024
            return vector if vector.size == dim
            return vector.first(dim) if vector.size > dim

            vector
          end

          def extract_tokens(response)
            usage = response[:usage]
            return usage.input_tokens.to_i if usage.respond_to?(:input_tokens)
            return usage[:input_tokens].to_i if usage.is_a?(Hash) && usage.key?(:input_tokens)

            0
          end

          def not_started_result(model, provider)
            { vector: nil, model: model, provider: provider, error: 'LLM not started' }
          end

          def unavailable_result(model, provider)
            { vector: nil, model: model, provider: provider, error: 'No embedding provider configured' }
          end
        end
      end
    end
  end
end
