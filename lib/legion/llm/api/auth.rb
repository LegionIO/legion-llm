# frozen_string_literal: true

require 'legion/logging/helper'

module Legion
  module LLM
    module API
      module Auth
        extend Legion::Logging::Helper

        def self.registered(app)
          log.debug('[llm][api][auth] registering /v1/* before filter')

          app.before '/v1/*' do
            log.debug("[llm][api][auth] before filter action=check path=#{request.path_info}")
            next unless auth_enabled?

            token = extract_token(request)
            log.debug("[llm][api][auth] action=validate token_present=#{!token.nil?}")

            unless valid_token?(token)
              log.warn("[llm][api][auth] action=rejected reason=invalid_token path=#{request.path_info}")
              halt 401, { 'Content-Type' => 'application/json' },
                   Legion::JSON.dump({ error: { message: 'Invalid API key', type: 'authentication_error' } })
            end

            log.debug("[llm][api][auth] action=authorized path=#{request.path_info}")
          end

          app.helpers do
            define_method(:auth_enabled?) do
              Legion::LLM.settings.dig(:api, :auth, :enabled) == true
            end

            define_method(:extract_token) do |req|
              auth_header = req.env['HTTP_AUTHORIZATION']
              if auth_header&.match?(/\ABearer\s+/i)
                log.debug('[llm][api][auth] token_source=bearer_header')
                return auth_header.sub(/\ABearer\s+/i, '')
              end

              key = req.env['HTTP_X_API_KEY']
              log.debug("[llm][api][auth] token_source=x_api_key present=#{!key.nil?}")
              key
            end

            define_method(:valid_token?) do |token|
              return true unless auth_enabled?
              return false if token.nil? || token.empty?

              keys = Legion::LLM.settings.dig(:api, :auth, :api_keys) || []
              keys.include?(token)
            end
          end

          log.debug('[llm][api][auth] /v1/* before filter registered')
        rescue StandardError => e
          handle_exception(e, level: :error, handled: false, operation: 'llm.api.auth.register')
        end
      end
    end
  end
end
