# frozen_string_literal: true

require_relative '../message'

module Legion
  module LLM
    module Fleet
      class Response < Legion::LLM::Transport::Message
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
        def publish(options = @options)
          raise unless @valid

          validate_payload_size
          channel.default_exchange.publish(
            encode_message,
            routing_key:      routing_key,
            content_type:     options[:content_type] || content_type,
            content_encoding: options[:content_encoding] || content_encoding,
            headers:          headers,
            type:             type,
            priority:         priority,
            message_id:       message_id,
            correlation_id:   correlation_id,
            app_id:           app_id,
            timestamp:        timestamp
          )
        rescue Bunny::ConnectionClosedError, Bunny::ChannelAlreadyClosed,
               Bunny::NetworkErrorWrapper, IOError, Timeout::Error => e
          spool_message(e)
        end

        private

        def message_id_prefix = 'resp'
      end
    end
  end
end
