# frozen_string_literal: true

require_relative '../message'

module Legion
  module LLM
    module Fleet
      class Request < Legion::LLM::Transport::Message
        PRIORITY_MAP = { critical: 9, high: 7, normal: 5, low: 2 }.freeze

        def type        = 'llm.fleet.request'
        def exchange    = Legion::LLM::Fleet::Exchange
        def routing_key = @options[:routing_key]
        def reply_to    = @options[:reply_to]
        def priority    = map_priority(@options[:priority])
        def expiration  = @options[:ttl] ? (@options[:ttl] * 1000).to_s : super

        private

        def message_id_prefix = 'req'

        def map_priority(val)
          return val if val.is_a?(Integer)

          PRIORITY_MAP.fetch(val, 5)
        end
      end
    end
  end
end
