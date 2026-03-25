# frozen_string_literal: true

module Legion
  module LLM
    module Embeddings
      PROVIDER_EMBEDDING_MODELS = {
        bedrock:   'amazon.titan-embed-text-v2',
        anthropic: nil,
        openai:    'text-embedding-3-small',
        gemini:    'text-embedding-004',
        azure:     'text-embedding-3-small',
        ollama:    'mxbai-embed-large'
      }.freeze

      class << self
        def generate(text:, model: nil, provider: nil, dimensions: nil)
          provider ||= resolve_provider
          model    ||= resolve_model(provider)
          opts = { model: model }
          opts[:provider]   = provider if provider
          opts[:dimensions] = dimensions if dimensions

          response = RubyLLM.embed(text, **opts)
          {
            vector:     response.vectors.first,
            model:      model,
            provider:   provider,
            dimensions: response.vectors.first&.size || 0,
            tokens:     response.input_tokens
          }
        rescue StandardError => e
          Legion::Logging.warn "Embedding failed (#{provider}/#{model}): #{e.message}" if defined?(Legion::Logging)
          { vector: nil, model: model, provider: provider, error: e.message }
        end

        def generate_batch(texts:, model: nil, provider: nil, dimensions: nil)
          provider ||= resolve_provider
          model    ||= resolve_model(provider)
          opts = { model: model }
          opts[:provider]   = provider if provider
          opts[:dimensions] = dimensions if dimensions

          response = RubyLLM.embed(texts, **opts)
          response.vectors.each_with_index.map do |vec, i|
            { vector: vec, model: model, provider: provider, dimensions: vec&.size || 0, index: i }
          end
        rescue StandardError => e
          Legion::Logging.warn("Batch embedding failed (#{provider}/#{model}): #{e.message}") if defined?(Legion::Logging)
          texts.map { |_| { vector: nil, model: model, provider: provider, error: e.message } }
        end

        def default_model
          resolve_model(resolve_provider)
        end

        private

        def resolve_provider
          configured = Legion::Settings.dig(:llm, :embeddings, :provider)
          return configured&.to_sym if configured

          Legion::Settings.dig(:llm, :default_provider)&.to_sym
        rescue StandardError
          nil
        end

        def resolve_model(provider)
          configured = Legion::Settings.dig(:llm, :embeddings, :default_model)
          return configured if configured

          provider_default = PROVIDER_EMBEDDING_MODELS[provider&.to_sym] if provider
          return provider_default if provider_default

          'text-embedding-3-small'
        rescue StandardError
          'text-embedding-3-small'
        end
      end
    end
  end
end
