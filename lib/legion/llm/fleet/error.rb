# frozen_string_literal: true

require_relative '../transport/message'

module Legion
  module LLM
    module Fleet
      class Error < Legion::LLM::Transport::Message
        ERROR_CODES = %w[
          model_not_loaded ollama_unavailable inference_failed inference_timeout
          invalid_token token_expired payload_too_large unsupported_type
          unsupported_streaming no_fleet_queue fleet_backpressure fleet_timeout
        ].freeze

        def type        = 'llm.fleet.error'
        def routing_key = @options[:reply_to]
        def priority    = 0
        def expiration  = nil
        def encrypt?    = false

        def headers
          super.merge(error_headers).merge(tracing_headers)
        end

        # Same default-exchange override as Fleet::Response.
        def publish(options = @options)
          raise unless @valid

          validate_payload_size
          channel.default_exchange.publish(
            encode_message,
            routing_key:      routing_key,
            content_type:     options[:content_type] || content_type,
            content_encoding: options[:content_encoding] || content_encoding,
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

        def message_id_prefix = 'err'

        def error_headers
          h = {}
          code = @options.dig(:error, :code)
          h['x-legion-fleet-error'] = code.to_s if code
          h
        end
      end
    end
  end
end
