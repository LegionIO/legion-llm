# frozen_string_literal: true

require 'sinatra/base'
require 'sinatra/extension'
require 'sinatra/namespace'
require 'legion/llm/token_estimation'

module Legion
  module LLM
    module API
      module Namespaces
        module Anthropic
          module Messages
            module CountTokens
              extend Sinatra::Extension

              post '/count_tokens' do
                require_llm!
                body = parse_request_body

                missing = []
                missing << 'model' if body[:model].nil? || body[:model].to_s.empty?
                missing << 'messages' if body[:messages].nil? || !body[:messages].is_a?(Array) || body[:messages].empty?
                unless missing.empty?
                  halt 400, { 'Content-Type' => 'application/json' },
                       Legion::JSON.dump({ type: 'error', error: { type: 'invalid_request_error', message: "missing required fields: #{missing.join(', ')}" } })
                end

                result = Legion::LLM::TokenEstimation.estimate(
                  messages: body[:messages],
                  model:    body[:model],
                  system:   body[:system],
                  tools:    body[:tools]
                )

                content_type :json
                status 200
                Legion::JSON.dump(result)
              rescue StandardError => e
                handle_exception(e, level: :error, handled: true, operation: 'llm.ns.anthropic.count_tokens')
                anthropic_error('api_error', e.message, status_code: 500)
              end
            end
          end
        end
      end
    end
  end
end
