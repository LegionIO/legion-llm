# frozen_string_literal: true

module Legion
  module LLM
    module Embeddings
      class << self
        def generate(text:, model: nil, dimensions: nil)
          model ||= default_model
          opts = { model: model }
          opts[:dimensions] = dimensions if dimensions

          response = RubyLLM.embed(text, **opts)
          {
            vector:     response.vectors.first,
            model:      model,
            dimensions: response.vectors.first&.size || 0,
            tokens:     response.input_tokens
          }
        rescue StandardError => e
          Legion::Logging.warn "Embedding failed: #{e.message}" if defined?(Legion::Logging)
          { vector: nil, model: model, error: e.message }
        end

        def generate_batch(texts:, model: nil, dimensions: nil)
          model ||= default_model
          opts = { model: model }
          opts[:dimensions] = dimensions if dimensions

          response = RubyLLM.embed(texts, **opts)
          response.vectors.each_with_index.map do |vec, i|
            { vector: vec, model: model, dimensions: vec&.size || 0, index: i }
          end
        rescue StandardError => e
          texts.map { |_| { vector: nil, model: model, error: e.message } }
        end

        def default_model
          Legion::Settings.dig(:llm, :embeddings, :default_model) || 'text-embedding-3-small'
        end
      end
    end
  end
end
