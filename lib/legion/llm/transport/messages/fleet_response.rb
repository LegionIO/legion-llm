# frozen_string_literal: true

require 'bunny'

require_relative '../message'

module Legion
  module LLM
    module Transport
      module Messages
        class FleetResponse < Legion::LLM::Transport::Message
          def type        = 'llm.fleet.response'
          def routing_key = @options[:reply_to]
          def priority    = 0
          def expiration  = nil

          def headers
            super.merge(tracing_headers)
          end

          # Override publish to use the AMQP default exchange ('').
          # The base class's publish calls exchange.publish(...), but the
          # default exchange is accessed via channel.default_exchange in Bunny.
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

          def message_id_prefix = 'resp'

          def reply_publish_defaults
            {
              mandatory:                  true,
              publisher_confirm:          true,
              publish_confirm_timeout_ms: 500,
              spool:                      false,
              return_result:              true
            }
          end
        end
      end
    end
  end
end
