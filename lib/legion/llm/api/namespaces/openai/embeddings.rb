# frozen_string_literal: true

require 'legion/logging/helper'
require 'legion/llm/api/namespaces/helpers'
require 'legion/llm/api/translators/openai_response'

module Legion
  module LLM
    module API
      module Namespaces
        module OpenAI
          module Embeddings
            extend Legion::Logging::Helper

            def self.registered(app)
              log.debug('[llm][api][namespaces][openai][embeddings] registering routes')

              app.post '/v1/embeddings' do
                require_llm!
                body  = parse_request_body
                input = body[:input]
                model = body[:model] || Legion::Settings[:llm][:default_model]

                if input.nil? || (input.respond_to?(:empty?) && input.empty?)
                  return openai_error('input is required', type: 'invalid_request_error',
                                                          param: 'input', code: nil, status_code: 400)
                end

                encoding_format = body[:encoding_format].to_s

                # One entry per input item, input order preserved (N -> N). A
                # single string goes through the same result-hash shape as a
                # batch so the response shaping below is one code path.
                if input.is_a?(Array)
                  embed_results = Legion::LLM.embed_batch(input, model: model)
                  log.info("[llm][api][namespaces][openai][embeddings] action=accepted model=#{model} input_count=#{input.size}")
                else
                  embed_results = [Legion::LLM.embed(input, model: model)]
                  log.info("[llm][api][namespaces][openai][embeddings] action=accepted model=#{model} input_length=#{input.to_s.length}")
                end

                entries = embed_results.map do |result|
                  vector = if result.is_a?(Hash)
                             result[:vector] || result['vector'] ||
                               result[:embedding] || result['embedding']
                           else
                             result
                           end
                  {
                    vector: vector.is_a?(Array) ? vector : [],
                    tokens: result.is_a?(Hash) ? (result[:tokens] || result['tokens']) : nil
                  }
                end

                response_body = Legion::LLM::API::Translators::OpenAIResponse.format_embeddings(
                  entries, model: model, input_texts: input, encoding_format: encoding_format
                )

                # The embed result hash carries the selected lane's attribution
                # (provider/instance/model) at the top level — flat-hash path.
                # Every batch entry shares the one selected lane, so entry 0
                # attributes the whole response.
                first_result = embed_results.first
                set_routing_response_headers(routing: first_result) if first_result.is_a?(Hash)

                log.info("[llm][api][namespaces][openai][embeddings] action=complete model=#{model} entries=#{entries.size} dims=#{entries.first[:vector].size}")

                audit_provider = first_result.is_a?(Hash) ? first_result[:provider].to_s : ''
                Legion::LLM::Audit.emit_prompt(
                  request_id:   SecureRandom.uuid,
                  caller:       build_server_caller(source: 'openai_embeddings', path: request.path, env: env),
                  routing:      { model: model, provider: audit_provider.empty? ? 'embed' : audit_provider },
                  tokens:       { input_tokens: response_body.dig(:usage, :prompt_tokens), output_tokens: 0 },
                  request_type: 'embedding',
                  timestamp:    Time.now
                )

                content_type :json
                Legion::JSON.dump(response_body)
              rescue Legion::LLM::AuthError => e
                handle_exception(e, level: :error, handled: true, operation: 'llm.api.namespaces.openai.embeddings.auth')
                openai_error(e.message, type: 'authentication_error', status_code: 401)
              rescue Legion::LLM::ProviderDown, Legion::LLM::ProviderError => e
                handle_exception(e, level: :error, handled: true, operation: 'llm.api.namespaces.openai.embeddings.provider')
                openai_error(e.message, type: 'server_error', status_code: 502)
              rescue Legion::LLM::Errors::RoutingRejected => e
                translate_routing_rejected(e, dialect: :openai, operation: 'llm.api.namespaces.openai.embeddings.routing_rejected')
              rescue StandardError => e
                handle_exception(e, level: :error, handled: false, operation: 'llm.api.namespaces.openai.embeddings')
                openai_error(e.message, type: 'server_error', status_code: 500)
              end

              log.debug('[llm][api][namespaces][openai][embeddings] routes registered')
            rescue StandardError => e
              handle_exception(e, level: :error, handled: false, operation: 'llm.api.namespaces.openai.embeddings.register')
            end
          end
        end
      end
    end
  end
end
