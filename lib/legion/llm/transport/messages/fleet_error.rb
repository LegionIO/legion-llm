# frozen_string_literal: true

require 'bunny'

require_relative '../message'

module Legion
  module LLM
    module Transport
      module Messages
        class FleetError < Legion::LLM::Transport::Message
          ERROR_CODES = %w[
            model_not_loaded ollama_unavailable inference_failed inference_timeout
            invalid_token token_expired payload_too_large unsupported_type
            unsupported_streaming no_fleet_queue fleet_backpressure fleet_timeout
            fleet_publish_failed fleet_publish_timeout
          ].freeze

          def type        = 'llm.fleet.error'
          def routing_key = @options[:reply_to]
          def priority    = 0
          def expiration  = nil
          def encrypt?    = false

          def headers
            super.merge(error_headers).merge(tracing_headers)
          end

          # Same default-exchange override as FleetResponse.
          def publish(options = nil)
            raise unless @valid

            publish_options = @options.merge(reply_publish_defaults).merge(options || {})
            publish_options[:routing_key] = routing_key
            validate_payload_size
            exchange_dest = channel.default_exchange
            return_state = {}
            install_return_listener(exchange_dest, publish_options, return_state)
            prepare_publisher_confirms(exchange_dest, publish_options)
            exchange_dest.publish(encode_message, **publish_envelope_options(publish_options))
            publish_result(exchange_dest, publish_options, return_state)
          rescue Bunny::ConnectionClosedError, Bunny::ChannelAlreadyClosed,
                 Bunny::NetworkErrorWrapper, IOError, Timeout::Error => e
            publish_failure_result(:failed, e)
          end

          private

          def message_id_prefix = 'err'

          def reply_publish_defaults
            {
              mandatory:                  true,
              publisher_confirm:          true,
              publish_confirm_timeout_ms: 500,
              spool:                      false,
              return_result:              true
            }
          end

          def error_headers
            h = {}
            error = @options[:error] || @options['error'] || {}
            code = error[:code] || error['code'] if error.is_a?(Hash)
            h['x-legion-fleet-error'] = code.to_s if code
            h
          end
        end
      end
    end
  end
end
