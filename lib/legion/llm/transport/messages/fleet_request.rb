# frozen_string_literal: true

require_relative '../message'

module Legion
  module LLM
    module Transport
      module Messages
        class FleetRequest < Legion::LLM::Transport::Message
          PRIORITY_MAP = { critical: 9, high: 7, normal: 5, low: 2 }.freeze

          def type        = 'llm.fleet.request'
          def exchange    = Legion::LLM::Transport::Exchanges::Fleet
          def routing_key = @options[:routing_key]
          def reply_to    = @options[:reply_to]
          def priority    = map_priority(@options[:priority])

          def expiration
            ttl_seconds = Float(@options[:ttl])
            return super unless ttl_seconds.positive?

            (ttl_seconds * 1000).ceil.to_s
          rescue ArgumentError, TypeError
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

            settings = Legion::LLM.settings
            nested_fetch(settings, :routing, :tiers, :fleet, :publish_confirm_timeout_ms) ||
              nested_fetch(settings, :routing, :fleet, :publish_confirm_timeout_ms) ||
              500
          rescue StandardError
            500
          end

          def fetch_option(hash, key)
            return nil unless hash.respond_to?(:key?)

            string_key = key.to_s
            return hash[string_key] if hash.key?(string_key)

            hash[key] if hash.key?(key)
          end

          def nested_fetch(hash, *keys)
            keys.reduce(hash) do |current, key|
              return nil unless current.respond_to?(:key?)

              fetch_option(current, key)
            end
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
