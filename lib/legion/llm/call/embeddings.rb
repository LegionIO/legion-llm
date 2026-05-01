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
            text = apply_prefix(coerce_text(text), model: model, task: task)

            response = Dispatch.call(
              provider:   provider,
              instance:   instance,
              capability: :embed,
              model:      model,
              text:       text,
              dimensions: dimensions
            )

            vector = normalize_vector(response[:result])
            vector = enforce_dimensions(vector) if enforce_dimension?

            {
              vector:     vector,
              model:      model,
              provider:   provider,
              dimensions: vector&.size || 0,
              tokens:     extract_tokens(response)
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
            texts = texts.map { |t| apply_prefix(coerce_text(t), model: model, task: task) }

            response = Dispatch.call(
              provider:   provider,
              instance:   instance,
              capability: :embed,
              model:      model,
              text:       texts,
              dimensions: dimensions
            )

            normalize_batch(response[:result], model, provider)
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
            base = model.to_s.split(':').first
            prefix = PREFIX_REGISTRY.dig(base, task)
            prefix ? "#{prefix}#{text}" : text
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
