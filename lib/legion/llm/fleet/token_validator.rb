# frozen_string_literal: true

require 'concurrent'
require 'time'

require_relative 'token_issuer'

module Legion
  module LLM
    module Fleet
      module TokenValidator
        @seen_jtis = Concurrent::Map.new

        module_function

        def validate!(token:, envelope:, record_replay: true)
          raise TokenError, 'fleet token is required' if token.to_s.empty?

          claims = symbolize_keys(jwt_module.verify(
                                    token,
                                    verification_key: signing_key,
                                    issuer:           TokenIssuer.issuer,
                                    algorithm:        TokenIssuer.algorithm,
                                    verify_issuer:    false
                                  ))
          validate_registered_claims!(claims)
          validate_request_expiry!(claims)
          validate_envelope_claims!(claims, symbolize_keys(envelope || {}))
          record_replay ? reject_replay!(claims[:jti]) : ensure_not_replayed!(claims[:jti])
          claims
        rescue TokenError
          raise
        rescue StandardError => e
          raise TokenError, "fleet token verification failed: #{e.message}"
        end

        def reset_replay_cache!
          @seen_jtis = Concurrent::Map.new
        end

        def validate_registered_claims!(claims)
          now = Time.now.to_i
          raise TokenError, 'fleet token issuer mismatch' unless accepted_issuer?(claims[:iss])
          raise TokenError, 'fleet token audience mismatch' unless claims[:aud].to_s == TokenIssuer.audience
          raise TokenError, 'fleet token expired' if claims[:exp].nil? || claims[:exp].to_i + clock_skew_seconds <= now
          raise TokenError, 'fleet token not yet valid' if claims[:nbf].nil? || claims[:nbf].to_i - clock_skew_seconds > now
          raise TokenError, 'fleet token missing jti' if claims[:jti].to_s.empty?
        end

        def validate_request_expiry!(claims)
          expires_at = claims[:expires_at]
          raise TokenError, 'fleet request expires_at is required' if expires_at.to_s.empty?

          expires = Time.iso8601(expires_at.to_s)
          raise TokenError, 'fleet request expired' if expires + clock_skew_seconds <= Time.now.utc
        rescue ArgumentError
          raise TokenError, 'fleet request expires_at is invalid'
        end

        def validate_envelope_claims!(claims, envelope)
          %i[
            request_id correlation_id idempotency_key operation provider provider_instance
            model reply_to message_context params caller trace_context timeout_seconds expires_at
          ].each do |key|
            expected = canonical_value(envelope[key])
            actual = canonical_value(claims[key])
            raise TokenError, "fleet token #{key} claim mismatch" unless actual == expected
          end
        end

        def reject_replay!(jti)
          ensure_not_replayed!(jti)
          @seen_jtis[jti.to_s] = Time.now.to_i + replay_ttl_seconds
        end

        def mark_replay!(jti)
          reject_replay!(jti)
        end

        def ensure_not_replayed!(jti)
          purge_replay_cache!
          existing_expiry = @seen_jtis[jti.to_s]
          raise TokenError, 'fleet token replay detected' if existing_expiry && existing_expiry > Time.now.to_i
        end

        def purge_replay_cache!
          now = Time.now.to_i
          @seen_jtis.each_pair { |jti, expires_at| @seen_jtis.delete(jti) if expires_at <= now }
        end

        def replay_ttl_seconds
          Legion::LLM::Settings.value(:fleet, :responder, :idempotency_ttl_seconds, default: 600).to_i
        rescue StandardError
          600
        end

        def accepted_issuer?(issuer)
          accepted_issuers.map(&:to_s).include?(issuer.to_s)
        end

        def accepted_issuers
          issuers = Legion::LLM::Settings.value(:fleet, :auth, :accepted_issuers, default: [TokenIssuer.issuer])
          issuers = [TokenIssuer.issuer] if Array(issuers).empty?
          Array(issuers)
        rescue StandardError
          [TokenIssuer.issuer]
        end

        def clock_skew_seconds
          Legion::LLM::Settings.value(:fleet, :auth, :max_clock_skew_seconds, default: 30).to_i
        rescue StandardError
          30
        end

        def signing_key
          TokenIssuer.signing_key
        end

        def jwt_module
          return Legion::Crypt::JWT if defined?(Legion::Crypt::JWT) && Legion::Crypt::JWT.respond_to?(:verify)

          raise TokenError, 'Legion::Crypt::JWT.verify unavailable'
        end

        def symbolize_keys(hash)
          return {} unless hash.respond_to?(:each)

          hash.each_with_object({}) do |(key, value), result|
            result[key.respond_to?(:to_sym) ? key.to_sym : key] = value
          end
        end

        def canonical_value(value)
          case value
          when Hash
            value.each_with_object({}) do |(key, child), result|
              result[key.to_s] = canonical_value(child)
            end.sort.to_h
          when Array
            value.map { |child| canonical_value(child) }
          when Symbol
            value.to_s
          else
            value
          end
        end
      end
    end
  end
end
