# frozen_string_literal: true

module Legion
  module LLM
    class EmbeddingUnavailableError < LLMError; end

    module Embeddings
      PROVIDER_EMBEDDING_MODELS = {
        bedrock:   'amazon.titan-embed-text-v2:0',
        anthropic: nil,
        openai:    'text-embedding-3-small',
        gemini:    'text-embedding-004',
        azure:     'text-embedding-3-small',
        ollama:    'mxbai-embed-large'
      }.freeze

      TARGET_DIMENSION = 1024

      class << self
        def generate(text:, model: nil, provider: nil, dimensions: nil)
          return { vector: nil, model: model, provider: provider, error: 'LLM not started' } unless LLM.started?

          provider ||= resolve_provider
          model    ||= resolve_model(provider)

          return generate_ollama(text: text, model: model) if provider&.to_sym == :ollama

          response   = RubyLLM.embed(text, **build_opts(model, provider, dimensions))
          vector     = apply_dimension_enforcement(response.vectors.first, provider)
          return dimension_error(model, provider, vector) if vector.is_a?(String)

          { vector: vector, model: model, provider: provider, dimensions: vector&.size || 0, tokens: response.input_tokens }
        rescue StandardError => e
          Legion::Logging.warn "Embedding failed (#{provider}/#{model}): #{e.message}" if defined?(Legion::Logging)
          handle_embed_failure(e, text: text, failed_provider: provider, failed_model: model)
        end

        def generate_batch(texts:, model: nil, provider: nil, dimensions: nil)
          return texts.map { |_| { vector: nil, error: 'LLM not started' } } unless LLM.started?

          provider ||= resolve_provider
          model    ||= resolve_model(provider)

          return generate_ollama_batch(texts: texts, model: model) if provider&.to_sym == :ollama

          response = RubyLLM.embed(texts, **build_opts(model, provider, dimensions))
          response.vectors.each_with_index.map do |vec, i|
            build_batch_entry(vec, model, provider, i)
          end
        rescue StandardError => e
          Legion::Logging.warn("Batch embedding failed (#{provider}/#{model}): #{e.message}") if defined?(Legion::Logging)
          texts.map { |_| { vector: nil, model: model, provider: provider, error: e.message } }
        end

        def default_model
          resolve_model(resolve_provider)
        end

        private

        def build_opts(model, provider, dimensions)
          target_dim = enforce_dimension? ? TARGET_DIMENSION : dimensions
          opts = { model: model }
          opts[:provider]   = provider if provider
          opts[:dimensions] = target_dim if target_dim && provider&.to_sym == :openai
          opts
        end

        def apply_dimension_enforcement(vector, provider)
          return vector unless enforce_dimension? && vector.is_a?(Array)

          enforce_dimensions(vector, provider)
        end

        def dimension_error(model, provider, message)
          { vector: nil, model: model, provider: provider, error: "incompatible dimension: #{message}" }
        end

        def build_batch_entry(vec, model, provider, index)
          vec = enforce_dimensions(vec, provider) if enforce_dimension? && vec.is_a?(Array)
          { vector: vec.is_a?(String) ? nil : vec, model: model, provider: provider,
            dimensions: vec.is_a?(Array) ? vec.size : 0, index: index }
        end

        def enforce_dimension?
          embedding_settings[:enforce_dimension] != false
        end

        def enforce_dimensions(vector, _provider)
          return vector if vector.size == TARGET_DIMENSION
          return vector.first(TARGET_DIMENSION) if vector.size > TARGET_DIMENSION

          "got #{vector.size}, need #{TARGET_DIMENSION} (provider cannot upscale)"
        end

        def handle_embed_failure(error, text:, failed_provider:, failed_model:)
          fallback = find_fallback_provider(failed_provider)
          if fallback
            Legion::Logging.info "Embedding failover: #{failed_provider} -> #{fallback[:provider]}" if defined?(Legion::Logging)
            LLM.instance_variable_set(:@embedding_provider, fallback[:provider])
            LLM.instance_variable_set(:@embedding_model, fallback[:model])
            generate(text: text, model: fallback[:model], provider: fallback[:provider])
          else
            { vector: nil, model: failed_model, provider: failed_provider, error: error.message }
          end
        end

        def find_fallback_provider(failed_provider)
          chain = embedding_settings[:provider_fallback] || %w[ollama bedrock openai]
          models = embedding_settings[:provider_models] || {}
          started = false

          chain.each do |name|
            sym = name.to_sym
            if sym == failed_provider
              started = true
              next
            end
            next unless started

            available = probe_fallback_provider(sym)
            next unless available

            model = available.is_a?(String) ? available : (models[name] || models[sym])&.to_s
            return { provider: sym, model: model }
          end
          nil
        end

        def probe_fallback_provider(sym)
          case sym
          when :ollama
            LLM.send(:detect_ollama_embedding,
                     embedding_settings[:ollama_preferred] || %w[mxbai-embed-large])
          else
            LLM.send(:detect_cloud_embedding, sym)
          end
        end

        def resolve_provider
          return LLM.embedding_provider if LLM.embedding_provider

          configured = embedding_settings[:provider]
          return configured&.to_sym if configured

          Legion::Settings.dig(:llm, :default_provider)&.to_sym
        rescue StandardError
          nil
        end

        def resolve_model(provider)
          return LLM.embedding_model if LLM.embedding_model && provider == LLM.embedding_provider

          configured = embedding_settings[:default_model]
          return configured if configured

          resolve_model_from_settings(provider)
        rescue StandardError
          'text-embedding-3-small'
        end

        def resolve_model_from_settings(provider)
          models = embedding_settings[:provider_models] || {}
          pm = models[provider&.to_sym] || models[provider.to_s]
          return pm.to_s if pm

          provider_default = PROVIDER_EMBEDDING_MODELS[provider&.to_sym] if provider
          return provider_default if provider_default

          'text-embedding-3-small'
        end

        def embedding_settings
          Legion::Settings.dig(:llm, :embedding) || {}
        rescue StandardError
          {}
        end

        def generate_ollama(text:, model:)
          result = ollama_embed_request(model: model, input: text)
          vector = result['embeddings']&.first
          vector = apply_dimension_enforcement(vector, :ollama) if vector
          return dimension_error(model, :ollama, vector) if vector.is_a?(String)

          { vector: vector, model: model, provider: :ollama, dimensions: vector&.size || 0, tokens: 0 }
        end

        def generate_ollama_batch(texts:, model:)
          result = ollama_embed_request(model: model, input: texts)
          vectors = result['embeddings'] || []
          vectors.each_with_index.map do |vec, i|
            build_batch_entry(vec, model, :ollama, i)
          end
        end

        def ollama_embed_request(model:, input:)
          base_url = Legion::Settings.dig(:llm, :providers, :ollama, :base_url) || 'http://localhost:11434'
          conn = Faraday.new(url: base_url) do |f|
            f.options.timeout = 30
            f.options.open_timeout = 5
            f.adapter Faraday.default_adapter
          end
          body = { model: model, input: input }
          response = conn.post('/api/embed', body.to_json, 'Content-Type' => 'application/json')
          raise "Ollama embed failed: #{response.status} #{response.body}" unless response.success?

          ::JSON.parse(response.body)
        end
      end
    end
  end
end
