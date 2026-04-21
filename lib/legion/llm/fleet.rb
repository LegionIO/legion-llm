# frozen_string_literal: true

require_relative 'fleet/dispatcher'
require_relative 'fleet/handler'
require_relative 'fleet/reply_dispatcher'

module Legion
  module LLM
    module Fleet
      def self.load_transport
        return unless defined?(Legion::Transport::Message)

        require_relative 'transport/exchanges/fleet'
        require_relative 'transport/messages/fleet_request'
        require_relative 'transport/messages/fleet_response'
        require_relative 'transport/messages/fleet_error'
      end
    end
  end
end
