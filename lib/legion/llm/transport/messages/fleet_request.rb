# frozen_string_literal: true

require 'legion/logging/helper'
require_relative '../message'

module Legion
  module LLM
    module Transport
      module Messages
        class FleetRequest < Legion::LLM::Transport::Message
          include Legion::Logging::Helper

          PRIORITY_MAP = { critical: 9, high: 7, normal: 5, low: 2 }.freeze

          def type        = 'llm.fleet.request'
          def exchange    = Legion::LLM::Transport::Exchanges::Fleet
          def routing_key = @options[:routing_key]
          def reply_to    = @options[:reply_to]
          def priority    = map_priority(@options[:priority])

          def expiration
            ttl = @options[:ttl]
            return super if ttl.nil? || ttl.to_s.strip.empty?

            ttl_seconds = Float(ttl)
            return super unless ttl_seconds.positive?

            (ttl_seconds * 1000).ceil.to_s
          rescue ArgumentError, TypeError => e
            handle_exception(e, level: :warn, handled: true, operation: 'llm.fleet_request.expiration', ttl: ttl)
            super
          end

          def message
            super.merge(reply_to: reply_to, correlation_id: correlation_id).compact
          end

          def publish(options = nil)
            super(default_publish_options.merge(options || {}))
          end

          private

          def message_id_prefix = 'req'

          def default_publish_options
            {
              mandatory:                  true,
              publisher_confirm:          true,
              publish_confirm_timeout_ms: publish_confirm_timeout_ms,
              spool:                      false,
              return_result:              true
            }
          end

          def publish_confirm_timeout_ms
            return 500 unless defined?(Legion::LLM) && Legion::LLM.respond_to?(:settings)

            Legion::LLM::Settings.value(:routing, :tiers, :fleet, :publish_confirm_timeout_ms) ||
              Legion::LLM::Settings.value(:routing, :fleet, :publish_confirm_timeout_ms) ||
              500
          rescue StandardError => e
            handle_exception(e, level: :warn, handled: true, operation: 'llm.fleet_request.publish_confirm_timeout')
            500
          end

          def map_priority(val)
            return val if val.is_a?(Integer)

            PRIORITY_MAP.fetch(val, 5)
          end
        end
      end
    end
  end
end
