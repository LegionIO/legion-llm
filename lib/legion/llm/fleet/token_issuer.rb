# frozen_string_literal: true

require 'securerandom'
require 'time'

module Legion
  module LLM
    module Fleet
      class TokenError < StandardError; end

      module TokenIssuer
        ISSUER = 'legion-llm'
        AUDIENCE = 'lex-llm-fleet-worker'
        ALGORITHM = 'HS256'

        module_function

        def issue(payload)
          ttl = token_ttl_seconds
          now = Time.now.to_i
          claims = required_claims(payload).merge(
            iss: issuer,
            aud: audience,
            iat: now,
            exp: now + ttl,
            nbf: now,
            jti: "fleet-jti-#{SecureRandom.uuid}"
          )

          jwt_module.issue(
            claims,
            signing_key: signing_key,
            ttl:         ttl,
            issuer:      issuer,
            algorithm:   algorithm
          )
        rescue TokenError
          raise
        rescue StandardError => e
          raise TokenError, "failed to issue fleet token: #{e.message}"
        end

        def required_claims(payload)
          payload = symbolize_keys(payload || {})
          claims = {}
          %i[
            request_id correlation_id idempotency_key operation provider provider_instance
            model reply_to message_context
          ].each do |key|
            value = payload[key]
            raise TokenError, "missing token claim source: #{key}" if value.nil?

            claims[key] = value
          end
          %i[params caller trace_context timeout_seconds expires_at].each do |key|
            value = payload[key]
            raise TokenError, "missing token claim source: #{key}" if value.nil?

            claims[key] = value
          end
          claims
        end

        def token_ttl_seconds
          Integer(Legion::LLM::Settings.value(:fleet, :dispatch, :token_ttl_seconds, default: 180))
        rescue ArgumentError, TypeError
          180
        end

        def issuer
          auth_setting(:issuer, default: ISSUER)
        end

        def audience
          auth_setting(:audience, default: AUDIENCE)
        end

        def algorithm
          auth_setting(:algorithm, default: ALGORITHM)
        end

        def auth_setting(key, default:)
          Legion::LLM::Settings.value(:fleet, :auth, key, default: default)
        rescue StandardError
          default
        end

        def signing_key
          require_crypt!
          return Legion::Crypt.cluster_secret if Legion::Crypt.respond_to?(:cluster_secret)

          raise TokenError, 'no signing key available - Legion::Crypt not initialized'
        rescue TokenError
          raise
        rescue StandardError => e
          raise TokenError, "no signing key available: #{e.message}"
        end

        def jwt_module
          require_crypt!
          return Legion::Crypt::JWT if defined?(Legion::Crypt::JWT) && Legion::Crypt::JWT.respond_to?(:issue)

          raise TokenError, 'Legion::Crypt::JWT.issue unavailable'
        end

        def require_crypt!
          return if defined?(Legion::Crypt)

          raise TokenError, 'Legion::Crypt is required for fleet token issuance'
        end

        def symbolize_keys(hash)
          hash.each_with_object({}) do |(key, value), result|
            result[key.respond_to?(:to_sym) ? key.to_sym : key] = value
          end
        end
      end
    end
  end
end
