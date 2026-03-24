# frozen_string_literal: true

module Legion
  module LLM
    module Fleet
      module Handler
        module_function

        def handle_fleet_request(payload)
          if Dispatcher.fleet_enabled? && !valid_token?(payload[:signed_token])
            error_response = { success: false, error: 'invalid_token' }
            publish_reply(payload[:reply_to], payload[:correlation_id], error_response) if payload[:reply_to]
            return error_response
          end

          response = call_local_llm(payload)
          response_hash = build_response(payload[:correlation_id], response)
          publish_reply(payload[:reply_to], payload[:correlation_id], response_hash) if payload[:reply_to]
          response_hash
        end

        def valid_token?(token)
          return true unless require_auth?
          return false if token.nil?
          return true unless defined?(Legion::Crypt)

          !Legion::Crypt.validate_jwt(token).nil?
        rescue StandardError
          false
        end

        def require_auth?
          return false unless defined?(Legion::Settings)

          settings = begin
            Legion::Settings[:llm]
          rescue StandardError
            nil
          end
          return false unless settings.is_a?(Hash)

          fleet = settings.dig(:routing, :fleet)
          return false unless fleet.is_a?(Hash)

          fleet.fetch(:require_auth, false)
        end

        def call_local_llm(payload)
          return { error: 'llm_not_available' } unless defined?(Legion::LLM)

          case payload[:request_type]&.to_s
          when 'structured'
            Legion::LLM.structured_direct(messages: payload[:messages], schema: payload[:schema])
          when 'embed'
            text = payload[:text] || payload.dig(:messages, 0, :content)
            Legion::LLM.embed_direct(text, model: payload[:model])
          else
            Legion::LLM.chat_direct(model: payload[:model], message: payload.dig(:messages, 0, :content))
          end
        end

        def build_response(correlation_id, response)
          {
            correlation_id: correlation_id,
            response: response,
            input_tokens: extract_token(response, :input_tokens),
            output_tokens: extract_token(response, :output_tokens),
            thinking_tokens: extract_token(response, :thinking_tokens),
            provider: extract_field(response, :provider),
            model_id: extract_field(response, :model)
          }
        end

        def publish_reply(reply_to, correlation_id, response_hash)
          return unless defined?(Legion::Transport)

          payload = if defined?(Legion::JSON)
                      Legion::JSON.dump(response_hash)
                    else
                      require 'json'
                      ::JSON.generate(response_hash)
                    end

          channel = Legion::Transport.connection.create_channel
          channel.default_exchange.publish(
            payload,
            routing_key: reply_to,
            correlation_id: correlation_id,
            content_type: 'application/json'
          )
          channel.close
        rescue StandardError => e
          Legion::Logging.warn("Fleet::Handler: publish_reply failed: #{e.message}") if defined?(Legion::Logging)
        end

        def extract_token(response, field)
          return 0 unless response.respond_to?(field)

          response.public_send(field).to_i
        end

        def extract_field(response, field)
          return nil unless response.respond_to?(field)

          response.public_send(field)
        end
      end
    end
  end
end
