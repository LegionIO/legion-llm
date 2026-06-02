# frozen_string_literal: true

require 'securerandom'
require 'legion/logging/helper'
require 'legion/llm/api/namespaces/helpers'

module Legion
  module LLM
    module API
      module Namespaces
        module OpenAI
          module Completions
            extend Legion::Logging::Helper

            def self.registered(app) # rubocop:disable Metrics/MethodLength
              log.debug('[llm][api][namespaces][openai][completions] registering routes')

              # rubocop:disable Metrics/BlockLength
              app.post '/v1/completions' do
                require_llm!
                body   = parse_request_body
                prompt = body[:prompt]

                if prompt.nil? || (prompt.respond_to?(:empty?) && prompt.empty?)
                  return openai_error('prompt is required', type: 'invalid_request_error',
                                                          code: nil, status_code: 400)
                end

                request_id = SecureRandom.uuid
                model      = body[:model] || Legion::Settings[:llm][:default_model] || 'default'
                messages   = [{ role: 'user', content: prompt.to_s }]

                log.info("[llm][api][namespaces][openai][completions] action=accepted request_id=#{request_id} model=#{model}")

                inference_request = Legion::LLM::Inference::Request.build(
                  id:       request_id,
                  messages: messages,
                  routing:  { model: model },
                  tools:    [],
                  caller:   build_server_caller(source: 'openai_completions', path: request.path, env: env),
                  stream:   false,
                  cache:    { strategy: :default, cacheable: true }
                )
                pipeline_response = Legion::LLM::Inference::Executor.new(inference_request).call

                routing        = pipeline_response.routing || {}
                tokens         = pipeline_response.tokens  || {}
                raw_msg        = pipeline_response.message
                text           = raw_msg.is_a?(Hash) ? (raw_msg[:content] || raw_msg['content']).to_s : raw_msg.to_s
                resolved_model = (routing[:model] || routing['model'] || model).to_s
                input_tokens  = Completions.extract_token(tokens, :input_tokens)
                output_tokens = Completions.extract_token(tokens, :output_tokens)

                log.info("[llm][api][namespaces][openai][completions] action=complete request_id=#{request_id} model=#{resolved_model}")
                content_type :json
                status 200
                Legion::JSON.dump({
                                    id:      "cmpl-#{request_id.delete('-')}",
                                    object:  'text_completion',
                                    created: Time.now.to_i,
                                    model:   resolved_model,
                                    choices: [{ text: text, index: 0, finish_reason: 'stop' }],
                                    usage:   {
                                      prompt_tokens:     input_tokens,
                                      completion_tokens: output_tokens,
                                      total_tokens:      input_tokens.to_i + output_tokens.to_i
                                    }
                                  })
              rescue Legion::LLM::AuthError => e
                handle_exception(e, level: :error, handled: true, operation: 'llm.api.namespaces.openai.completions.auth')
                openai_error(e.message, type: 'authentication_error', status_code: 401)
              rescue Legion::LLM::RateLimitError => e
                handle_exception(e, level: :warn, handled: true, operation: 'llm.api.namespaces.openai.completions.rate_limit')
                openai_error(e.message, type: 'rate_limit_error', code: 'rate_limit_exceeded', status_code: 429)
              rescue Legion::LLM::ProviderDown, Legion::LLM::ProviderError => e
                handle_exception(e, level: :error, handled: true, operation: 'llm.api.namespaces.openai.completions.provider')
                openai_error(e.message, type: 'server_error', status_code: 502)
              rescue StandardError => e
                handle_exception(e, level: :error, handled: false, operation: 'llm.api.namespaces.openai.completions')
                openai_error(e.message, type: 'server_error', status_code: 500)
              end
              # rubocop:enable Metrics/BlockLength

              log.debug('[llm][api][namespaces][openai][completions] routes registered')
            rescue StandardError => e
              handle_exception(e, level: :error, handled: false, operation: 'llm.api.namespaces.openai.completions.register')
            end

            def self.extract_token(tokens, key)
              return 0 if tokens.nil?

              if tokens.is_a?(Hash)
                v = tokens[key] || tokens[key.to_s]
                return v.to_i unless v.nil?
              end

              method_name = { input_tokens: :input_tokens, output_tokens: :output_tokens }[key]
              return tokens.public_send(method_name).to_i if method_name && tokens.respond_to?(method_name)

              0
            end
          end
        end
      end
    end
  end
end
