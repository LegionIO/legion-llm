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
                model = body[:model] || Legion::LLM::Settings.value(:default_model)

                if input.nil? || (input.respond_to?(:empty?) && input.empty?)
                  return openai_error('input is required', type: 'invalid_request_error',
                                                          code: nil, status_code: 400)
                end

                text = input.is_a?(Array) ? input.first.to_s : input.to_s
                log.info("[llm][api][namespaces][openai][embeddings] action=accepted model=#{model} input_length=#{text.length}")

                vector = Legion::LLM.embed(text, model: model)
                vector_array = case vector
                               when Array then vector
                               when Hash  then vector[:vector] || vector['vector'] ||
                                               vector[:embedding] || vector['embedding'] || []
                               else []
                               end
                usage = vector.is_a?(Hash) ? (vector[:usage] || vector['usage'] || vector) : nil

                response_body = Legion::LLM::API::Translators::OpenAIResponse.format_embeddings(
                  vector_array, model: model, input_text: text, usage: usage
                )

                log.info("[llm][api][namespaces][openai][embeddings] action=complete model=#{model} dims=#{vector_array.size}")

                Legion::LLM::Audit.emit_prompt(
                  request_id:   SecureRandom.uuid,
                  caller:       build_server_caller(source: 'openai_embeddings', path: request.path, env: env),
                  routing:      { model: model, provider: 'embed' },
                  tokens:       { input_tokens: (text.length / 4.0).ceil, output_tokens: 0 },
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
