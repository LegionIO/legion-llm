# frozen_string_literal: true

require 'legion/extensions/llm/transport/messages/fleet_response'

module Legion
  module LLM
    module Transport
      module Messages
        class FleetResponse
          def initialize(*, **)
            raise NotImplementedError,
                  'Use Legion::Extensions::Llm::Transport::Messages::FleetResponse'
          end
        end
      end
    end
  end
end
