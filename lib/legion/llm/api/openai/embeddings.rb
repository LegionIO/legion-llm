# frozen_string_literal: true

require 'legion/logging/helper'

module Legion
  module LLM
    module API
      module OpenAI
        module Embeddings
          extend Legion::Logging::Helper

          def self.registered(app)
            log.debug('[llm][api][openai][embeddings] registering POST /v1/embeddings')

            app.post '/v1/embeddings' do
              require_llm!
              body = parse_request_body

              input = body[:input] || body['input']
              model = body[:model] || body['model'] || Legion::LLM.settings[:default_model]

              if input.nil? || (input.respond_to?(:empty?) && input.empty?)
                halt 400, { 'Content-Type' => 'application/json' },
                     Legion::JSON.dump({ error: { message: 'input is required',
                                                  type: 'invalid_request_error', param: 'input', code: nil } })
              end

              text = input.is_a?(Array) ? input.first.to_s : input.to_s

              log.info("[llm][api][openai][embeddings] action=accepted model=#{model} input_length=#{text.length}")

              vector = Legion::LLM.embed(text, model: model)
              vector_array = case vector
                             when Array then vector
                             when Hash  then vector[:vector] || vector['vector'] || vector[:embedding] || vector['embedding'] || []
                             else []
                             end

              response_body = Legion::LLM::API::Translators::OpenAIResponse.format_embeddings(
                vector_array, model: model, input_text: text
              )

              log.info("[llm][api][openai][embeddings] action=complete model=#{model} dims=#{vector_array.size}")
              content_type :json
              Legion::JSON.dump(response_body)
            rescue Legion::LLM::AuthError => e
              handle_exception(e, level: :error, handled: true, operation: 'llm.api.openai.embeddings.auth')
              halt 401, { 'Content-Type' => 'application/json' },
                   Legion::JSON.dump({ error: { message: e.message, type: 'authentication_error' } })
            rescue Legion::LLM::ProviderDown, Legion::LLM::ProviderError => e
              handle_exception(e, level: :error, handled: true, operation: 'llm.api.openai.embeddings.provider')
              halt 502, { 'Content-Type' => 'application/json' },
                   Legion::JSON.dump({ error: { message: e.message, type: 'server_error' } })
            rescue StandardError => e
              handle_exception(e, level: :error, handled: false, operation: 'llm.api.openai.embeddings')
              halt 500, { 'Content-Type' => 'application/json' },
                   Legion::JSON.dump({ error: { message: e.message, type: 'server_error' } })
            end

            log.debug('[llm][api][openai][embeddings] POST /v1/embeddings registered')
          end
        end
      end
    end
  end
end
