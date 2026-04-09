# frozen_string_literal: true

require_relative '../transport/message'

module Legion
  module LLM
    module Metering
      class Event < Legion::LLM::Transport::Message
        def type        = 'llm.metering.event'
        def exchange    = Legion::LLM::Transport::Exchanges::Metering
        def routing_key = "metering.#{@options[:request_type]}"
        def priority    = 0
        def encrypt?    = false
        def expiration  = nil

        def headers
          super.merge(tier_header)
        end

        private

        def message_id_prefix = 'meter'

        def tier_header
          h = {}
          h['x-legion-llm-tier'] = @options[:tier].to_s if @options[:tier]
          h
        end
      end
    end
  end
end
