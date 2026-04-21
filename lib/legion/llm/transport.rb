# frozen_string_literal: true

module Legion
  module LLM
    module Transport
      def self.load_all
        return unless defined?(::Legion::Transport::Message)

        require_relative 'transport/message'

        require_relative 'transport/exchanges/audit'
        require_relative 'transport/exchanges/escalation'
        require_relative 'transport/exchanges/fleet'
        require_relative 'transport/exchanges/metering'
        Dir[File.join(__dir__, 'transport/messages', '*.rb')].each { |f| require f }
      end
    end
  end
end
