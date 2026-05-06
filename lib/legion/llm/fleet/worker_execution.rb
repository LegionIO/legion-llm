# frozen_string_literal: true

require 'concurrent'

require_relative 'token_validator'

module Legion
  module LLM
    module Fleet
      module WorkerExecution
        class PolicyError < StandardError; end

        @idempotency_keys = Concurrent::Map.new

        module_function

        def call(envelope:, provider:)
          claims = validate_identity!(envelope)
          validate_policy!(envelope)
          idempotency_key = validate_idempotency!(envelope)
          response = dispatch_local_provider!(envelope: envelope, provider: provider)
          mark_idempotency_success!(idempotency_key) if idempotency_key
          TokenValidator.mark_replay!(claims[:jti]) if claims.is_a?(Hash)
          response
        rescue TokenError => e
          release_idempotency!(idempotency_key) if idempotency_key
          raise PolicyError, e.message
        rescue StandardError
          release_idempotency!(idempotency_key) if idempotency_key
          raise
        end

        def validate_identity!(envelope)
          return true unless responder_setting(:require_auth, default: true)

          TokenValidator.validate!(token: envelope_value(envelope, :signed_token), envelope: envelope,
                                   record_replay: false)
        end

        def validate_policy!(_envelope)
          return true unless responder_setting(:require_policy, default: false)

          raise PolicyError, 'fleet responder policy enforcement unavailable'
        end

        def validate_idempotency!(envelope)
          return nil unless responder_setting(:require_idempotency, default: true)

          purge_idempotency_cache!
          key = envelope_value(envelope, :idempotency_key)
          raise PolicyError, 'fleet idempotency_key is required' if key.to_s.empty?

          reserve_idempotency_key!(key.to_s)
          key.to_s
        end

        def dispatch_local_provider!(envelope:, provider:)
          provider = provider.call(envelope) if provider.respond_to?(:call) && !provider.respond_to?(:chat)
          operation = envelope_value(envelope, :operation).to_sym
          params = normalize_hash(envelope_value(envelope, :params) || {})
          model = envelope_value(envelope, :model)

          case operation
          when :chat
            provider.chat(messages: params.fetch(:messages, []), model: model, **params.except(:messages))
          when :stream
            provider.stream_chat(messages: params.fetch(:messages, []), model: model, **params.except(:messages))
          when :embed
            provider.embed(text: params[:text], model: model, dimensions: params[:dimensions])
          when :count_tokens
            provider.count_tokens(messages: params.fetch(:messages, []), model: model, **params.except(:messages))
          else
            raise PolicyError, "unsupported fleet operation: #{operation}"
          end
        end

        def reset_idempotency_cache!
          @idempotency_keys = Concurrent::Map.new
        end

        def mark_idempotency_success!(key)
          @idempotency_keys[key.to_s] = { state: :complete, expires_at: Time.now.to_i + idempotency_ttl_seconds }
        end

        def release_idempotency!(key)
          @idempotency_keys.delete(key.to_s)
        end

        def purge_idempotency_cache!
          now = Time.now.to_i
          @idempotency_keys.each_pair do |key, entry|
            @idempotency_keys.delete(key) if entry[:expires_at] <= now
          end
        end

        def reserve_idempotency_key!(key)
          entry = { state: :inflight, expires_at: Time.now.to_i + idempotency_ttl_seconds }
          existing = @idempotency_keys.put_if_absent(key, entry)
          return true unless existing && existing[:expires_at] > Time.now.to_i

          raise PolicyError, 'duplicate fleet idempotency key'
        end

        def idempotency_ttl_seconds
          ttl = responder_setting(:idempotency_ttl_seconds, default: 600).to_i
          ttl.positive? ? ttl : 600
        end

        def responder_setting(key, default:)
          value = Legion::LLM::Settings.value(:fleet, :responder, key, default: nil)
          return auth_required? if key == :require_auth && value.nil?
          return default if value.nil?

          value
        end

        def auth_required?
          Legion::LLM::Settings.value(:fleet, :auth, :require_signed_token, default: true) != false
        end

        def envelope_value(envelope, key)
          return nil unless envelope.respond_to?(:key?)

          envelope[key] || envelope[key.to_s]
        end

        def normalize_hash(hash)
          return {} unless hash.respond_to?(:each)

          hash.each_with_object({}) do |(key, value), result|
            result[key.respond_to?(:to_sym) ? key.to_sym : key] = value
          end
        end
      end
    end
  end
end
