# frozen_string_literal: true

require_relative 'fleet/dispatcher'
require_relative 'fleet/handler'
require_relative 'fleet/lane'
require_relative 'fleet/provider_responder'
require_relative 'fleet/reply_dispatcher'
require_relative 'fleet/token_issuer'
require_relative 'fleet/token_validator'
require_relative 'fleet/worker_execution'

module Legion
  module LLM
    module Fleet
      def self.load_transport
        return unless defined?(Legion::Transport::Message)

        require 'legion/extensions/llm/transport/messages/fleet_request'
        require 'legion/extensions/llm/transport/messages/fleet_response'
        require 'legion/extensions/llm/transport/messages/fleet_error'
        require_relative 'transport/exchanges/fleet'
        require_relative 'transport/messages/fleet_request'
        require_relative 'transport/messages/fleet_response'
        require_relative 'transport/messages/fleet_error'
      end

      # Backward-compat: resolve old Legion::LLM::Fleet::Exchange, ::Request, ::Response, ::Error
      def self.const_missing(name)
        case name
        when :Exchange
          require_relative 'transport/exchanges/fleet'
          Transport::Exchanges::Fleet
        when :Request
          require 'legion/extensions/llm/transport/messages/fleet_request'
          ::Legion::Extensions::Llm::Transport::Messages::FleetRequest
        when :Response
          require 'legion/extensions/llm/transport/messages/fleet_response'
          ::Legion::Extensions::Llm::Transport::Messages::FleetResponse
        when :Error
          require 'legion/extensions/llm/transport/messages/fleet_error'
          ::Legion::Extensions::Llm::Transport::Messages::FleetError
        else
          super
        end
      end
    end
  end
end
