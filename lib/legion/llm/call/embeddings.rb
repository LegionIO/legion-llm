# frozen_string_literal: true

require 'legion/logging/helper'
module Legion
  module LLM
    class EmbeddingUnavailableError < LLMError; end

    module Call
      module Embeddings
        extend Legion::Logging::Helper

        PROVIDER_EMBEDDING_MODELS = {
          bedrock:   'amazon.titan-embed-text-v2:0',
          anthropic: nil,
          openai:    'text-embedding-3-small',
          gemini:    'text-embedding-004',
          azure:     'text-embedding-3-small',
          ollama:    'mxbai-embed-large'
        }.freeze

        TARGET_DIMENSION = 1024

        OLLAMA_CONTEXT_CHARS = {
          'mxbai-embed-large'      => 1400,
          'bge-large'              => 1400,
          'snowflake-arctic-embed' => 1400,
          'nomic-embed-text'       => 24_000
        }.freeze
        OLLAMA_DEFAULT_CONTEXT_CHARS = 1400

        PREFIX_REGISTRY = {
          'nomic-embed-text'  => { document: 'search_document: ', query: 'search_query: ' },
          'mxbai-embed-large' => { query: 'Represent this sentence for searching relevant passages: ' }
        }.freeze

        class << self
          def generate(text:, model: nil, provider: nil, dimensions: nil, task: :document)
            return { vector: nil, model: model, provider: provider, error: 'LLM not started' } unless LLM.started?

            provider ||= resolve_provider
            return { vector: nil, model: model, provider: provider, error: "provider #{provider} is disabled" } if provider_disabled?(provider)

            model ||= resolve_model(provider)
            text    = coerce_text_input(text)
            text    = apply_prefix(text, model: model, task: task)

            return generate_ollama(text: text, model: model) if provider&.to_sym == :ollama
            return generate_azure(text: text, model: model, dimensions: dimensions) if provider&.to_sym == :azure
            return { vector: nil, model: model, provider: provider, error: "provider #{provider} does not support embeddings" } \
              if provider && !provider_supports_embeddings?(provider)

            response   = RubyLLM.embed(text, **build_opts(model, provider, dimensions))
            vector     = apply_dimension_enforcement(response.vectors.first, provider)
            return dimension_error(model, provider, vector) if vector.is_a?(String)

            { vector: vector, model: model, provider: provider, dimensions: vector&.size || 0, tokens: response.input_tokens }
          rescue StandardError => e
            handle_exception(e, level: :warn)
            handle_embed_failure(e, text: text, failed_provider: provider, failed_model: model)
          end

          def generate_batch(texts:, model: nil, provider: nil, dimensions: nil, task: :document)
            return texts.map { |_| { vector: nil, error: 'LLM not started' } } unless LLM.started?

            provider ||= resolve_provider
            disabled_result = disabled_batch_result(texts, provider, model)
            return disabled_result if disabled_result

            model  ||= resolve_model(provider)
            texts    = texts.map { |t| apply_prefix(coerce_text_input(t), model: model, task: task) }

            return generate_ollama_batch(texts: texts, model: model) if provider&.to_sym == :ollama
            return generate_azure_batch(texts: texts, model: model, dimensions: dimensions) if provider&.to_sym == :azure

            response = RubyLLM.embed(texts, **build_opts(model, provider, dimensions))
            response.vectors.each_with_index.map do |vec, i|
              build_batch_entry(vec, model, provider, i)
            end
          rescue StandardError => e
            handle_exception(e, level: :warn)
            texts.map { |_| { vector: nil, model: model, provider: provider, error: e.message } }
          end

          def default_model
            resolve_model(resolve_provider)
          end

          private

          def disabled_batch_result(texts, provider, model)
            return nil unless provider_disabled?(provider)

            model ||= resolve_model(provider)
            texts.each_with_index.map do |_, i|
              { vector: nil, model: model, provider: provider, dimensions: 0, index: i, error: "provider #{provider} is disabled" }
            end
          end

          def provider_disabled?(provider)
            return false unless provider

            config = Legion::Settings.dig(:llm, :providers, provider.to_sym)
            config.is_a?(Hash) && config[:enabled] == false
          rescue StandardError => e
            handle_exception(e, level: :debug, operation: 'llm.embeddings.provider_disabled', provider: provider)
            false
          end

          def provider_supports_embeddings?(provider)
            return Discovery.send(:provider_supports_embeddings?, provider) if defined?(Discovery)
            return true unless LLM.respond_to?(:provider_supports_embeddings?, true)

            LLM.send(:provider_supports_embeddings?, provider)
          rescue StandardError => e
            handle_exception(e, level: :debug, operation: 'llm.embeddings.provider_supports_embeddings', provider: provider)
            false
          end

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
              generate(text: text, model: fallback[:model], provider: fallback[:provider])
            else
              { vector: nil, model: failed_model, provider: failed_provider, error: error.message }
            end
          end

          def find_fallback_provider(failed_provider)
            chain = LLM.embedding_fallback_chain
            return nil unless chain.is_a?(Array) && chain.any?

            started = false
            chain.each do |entry|
              if entry[:provider] == failed_provider&.to_sym
                started = true
                next
              end
              next unless started
              # Skip providers that are explicitly disabled in the fallback chain
              next if provider_disabled?(entry[:provider])
              next unless provider_supports_embeddings?(entry[:provider])

              log.info "Embedding failover: #{failed_provider} -> #{entry[:provider]}"
              return entry
            end
            nil
          end

          def resolve_provider
            return LLM.embedding_provider if LLM.embedding_provider

            configured = embedding_settings[:provider]
            return configured&.to_sym if configured

            Legion::Settings.dig(:llm, :default_provider)&.to_sym
          rescue StandardError => e
            handle_exception(e, level: :debug, operation: 'llm.embeddings.resolve_provider')
            nil
          end

          def resolve_model(provider)
            return LLM.embedding_model if LLM.embedding_model && provider == LLM.embedding_provider

            configured = embedding_settings[:default_model]
            return configured if configured

            resolve_model_from_settings(provider)
          rescue StandardError => e
            handle_exception(e, level: :debug, operation: 'llm.embeddings.resolve_model', provider: provider)
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

          def apply_prefix(text, model:, task:)
            return text unless prefix_injection_enabled?

            base_model = model.to_s.split(':').first
            prefixes   = PREFIX_REGISTRY[base_model]
            return text unless prefixes

            prefix = prefixes[task.to_sym]
            return text unless prefix

            "#{prefix}#{text}"
          end

          def coerce_text_input(value)
            case value
            when String
              value
            when Array
              parts = value.filter_map { |entry| extract_text_fragment(entry) }
              joined = parts.map(&:to_s).map(&:strip).reject(&:empty?).join("\n")
              joined.empty? ? value.to_s : joined
            when Hash
              extract_text_fragment(value).to_s
            when nil
              ''
            else
              value.to_s
            end
          end

          def extract_text_fragment(value)
            case value
            when String
              value
            when Array
              value.filter_map { |entry| extract_text_fragment(entry) }.join("\n")
            when Hash
              text = value[:text] || value['text']
              return text.to_s if text.is_a?(String)

              content = value[:content] || value['content']
              return extract_text_fragment(content) unless content.nil?

              %i[query prompt message input value summary].each do |key|
                candidate = value[key] || value[key.to_s]
                return extract_text_fragment(candidate) unless candidate.nil?
              end

              value.values.filter_map { |entry| extract_text_fragment(entry) }.join("\n")
            else
              value.to_s
            end
          end

          def prefix_injection_enabled?
            value = (Legion::Settings.dig(:llm, :embedding) || {})[:prefix_injection]
            value.nil? || value
          rescue StandardError => e
            handle_exception(e, level: :debug, operation: 'llm.embeddings.prefix_injection_enabled')
            true
          end

          def embedding_settings
            Legion::Settings.dig(:llm, :embedding) || {}
          rescue StandardError => e
            handle_exception(e, level: :debug, operation: 'llm.embeddings.embedding_settings')
            {}
          end

          def generate_ollama(text:, model:)
            ctx_max = ollama_context_chars(model)
            return generate_ollama_chunked(text: text, model: model, max_chars: ctx_max) if text.length > ctx_max

            result = ollama_embed_request(model: model, input: text)
            vector = extract_ollama_vectors(result).first
            vector = apply_dimension_enforcement(vector, :ollama) if vector
            return dimension_error(model, :ollama, vector) if vector.is_a?(String)

            { vector: vector, model: model, provider: :ollama, dimensions: vector&.size || 0, tokens: 0 }
          rescue RuntimeError => e
            raise unless e.message.include?('input length exceeds')

            reduced = (ctx_max * 0.6).to_i
            log.info("Ollama context exceeded, retrying with chunking at #{reduced} chars")
            generate_ollama_chunked(text: text, model: model, max_chars: reduced)
          end

          def generate_ollama_chunked(text:, model:, max_chars:)
            chunks = chunk_text(text, max_chars: max_chars)
            vectors = chunks.filter_map do |chunk|
              result = ollama_embed_request(model: model, input: chunk[:content])
              extract_ollama_vectors(result).first
            end

            return { vector: nil, model: model, provider: :ollama, error: 'all chunks failed embedding' } if vectors.empty?

            avg = average_vectors(vectors)
            avg = apply_dimension_enforcement(avg, :ollama)
            return dimension_error(model, :ollama, avg) if avg.is_a?(String)

            { vector: avg, model: model, provider: :ollama, dimensions: avg.size, tokens: 0, chunks: vectors.size }
          end

          def generate_ollama_batch(texts:, model:)
            max_chars = ollama_context_chars(model)
            texts.each_with_index.map do |text, i|
              if text.length > max_chars
                result = generate_ollama_chunked(text: text, model: model, max_chars: max_chars)
                build_batch_entry(result[:vector], model, :ollama, i)
              else
                result = ollama_embed_request(model: model, input: text)
                vec = extract_ollama_vectors(result).first
                build_batch_entry(vec, model, :ollama, i)
              end
            end
          end

          def chunk_text(text, max_chars:)
            if defined?(Legion::Extensions::Knowledge::Helpers::Chunker)
              chunker = Legion::Extensions::Knowledge::Helpers::Chunker
              max_tokens = max_chars / chunker::CHARS_PER_TOKEN
              sections = [{ content: text, heading: nil, section_path: nil, source_file: nil }]
              chunker.chunk(sections: sections, max_tokens: max_tokens)
            else
              text.chars.each_slice(max_chars).map { |s| { content: s.join } }
            end
          rescue StandardError => e
            handle_exception(e, level: :debug, operation: 'llm.embeddings.chunk_text')
            text.chars.each_slice(max_chars).map { |s| { content: s.join } }
          end

          def average_vectors(vectors)
            return vectors.first if vectors.size == 1

            dim = vectors.first.size
            sum = Array.new(dim, 0.0)
            vectors.each { |v| v.each_with_index { |val, i| sum[i] += val } }
            sum.map { |s| s / vectors.size }
          end

          def ollama_context_chars(model)
            base = model.to_s.split(':').first
            OLLAMA_CONTEXT_CHARS[base] || OLLAMA_DEFAULT_CONTEXT_CHARS
          end

          # ── Azure OpenAI (direct HTTP with SNI, bypasses ruby_llm) ──

          def generate_azure(text:, model:, dimensions: nil)
            result = azure_embed_request(model: model, input: text, dimensions: dimensions)
            vector = result.dig('data', 0, 'embedding')
            vector = apply_dimension_enforcement(vector, :azure) if vector
            return dimension_error(model, :azure, vector) if vector.is_a?(String)

            tokens = result.dig('usage', 'total_tokens') || 0
            { vector: vector, model: model, provider: :azure, dimensions: vector&.size || 0, tokens: tokens }
          end

          def generate_azure_batch(texts:, model:, dimensions: nil)
            result = azure_embed_request(model: model, input: texts, dimensions: dimensions)
            (result['data'] || []).each_with_index.map do |entry, i|
              build_batch_entry(entry['embedding'], model, :azure, i)
            end
          rescue StandardError => e
            handle_exception(e, level: :warn)
            texts.map { |_| { vector: nil, model: model, provider: :azure, error: e.message } }
          end

          def azure_embed_request(model:, input:, dimensions: nil)
            settings = azure_embedding_settings
            api_base = settings[:api_base]
            api_key  = settings[:api_key]
            ip       = settings[:ip]
            raise 'Azure OpenAI embedding not configured (llm.providers.azure.api_base required)' unless api_base

            host = URI.parse(api_base).host
            target_ip = ip
            path = "/openai/deployments/#{model}/embeddings?api-version=2024-02-01"
            log.info "Azure embed connecting to #{host}:443 (ip_override=#{target_ip.inspect})"

            require 'net/http'
            require 'openssl'
            http = Net::HTTP.new(host, 443)
            http.use_ssl = true
            http.verify_mode = OpenSSL::SSL::VERIFY_PEER
            http.open_timeout = 10
            http.read_timeout = 30

            # When an IP override is set, resolve the FQDN to the private endpoint IP
            # while keeping the FQDN as SNI for TLS handshake
            if target_ip
              addr = Addrinfo.tcp(target_ip, 443)
              http.ipaddr = addr.ip_address
            end

            req = Net::HTTP::Post.new(path)
            req['Content-Type'] = 'application/json'
            req['api-key'] = api_key
            body = { input: input }
            body[:dimensions] = dimensions || TARGET_DIMENSION
            req.body = ::JSON.dump(body)

            response = http.request(req)
            raise "Azure embed failed: #{response.code} #{response.body}" unless response.is_a?(Net::HTTPSuccess)

            ::JSON.parse(response.body)
          end

          def azure_embedding_settings
            base = Legion::Settings.dig(:llm, :providers, :azure) || {}
            embed = Legion::Settings.dig(:llm, :embedding, :azure) || {}
            {
              api_base: embed[:api_base] || base[:api_base],
              api_key:  embed[:api_key] || base[:api_key] || base[:auth_token],
              ip:       embed[:ip]
            }
          end

          # ── Ollama (direct HTTP, bypasses ruby_llm) ──

          def ollama_embed_request(model:, input:)
            base_url = Legion::Settings.dig(:llm, :providers, :ollama, :base_url) || 'http://localhost:11434'
            conn = Faraday.new(url: base_url) do |f|
              f.options.timeout = 30
              f.options.open_timeout = 5
              f.adapter Faraday.default_adapter
            end
            body = { model: model, input: input }
            response = conn.post('/api/embed', body.to_json, 'Content-Type' => 'application/json')
            return ::JSON.parse(response.body) if response.success?

            if ollama_legacy_retry?(response, input)
              log.info 'Ollama embed retrying with legacy /api/embeddings compatibility path'
              legacy_body = { model: model, prompt: input }
              legacy_response = conn.post('/api/embeddings', legacy_body.to_json, 'Content-Type' => 'application/json')
              raise "Ollama embed failed: #{legacy_response.status} #{legacy_response.body}" unless legacy_response.success?

              return ::JSON.parse(legacy_response.body)
            end

            raise "Ollama embed failed: #{response.status} #{response.body}"
          end

          def ollama_legacy_retry?(response, input)
            return false unless input.is_a?(String)
            return true if response.status == 404

            body = response.body.to_s.downcase
            response.status == 400 && body.include?('invalid input type')
          end

          def extract_ollama_vectors(result)
            embeddings = result['embeddings']
            return [] if embeddings == []
            return embeddings if embeddings.is_a?(Array) && embeddings.first.is_a?(Array)
            return [embeddings] if embeddings.is_a?(Array)

            embedding = result['embedding']
            return [embedding] if embedding.is_a?(Array)

            []
          end
        end
      end
    end
  end
end
