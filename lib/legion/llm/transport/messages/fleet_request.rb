# frozen_string_literal: true

require 'legion/extensions/llm/transport/messages/fleet_request'

module Legion
  module LLM
    module Transport
      module Messages
        class FleetRequest
          def initialize(*, **)
            raise NotImplementedError,
                  'Use Legion::Extensions::Llm::Transport::Messages::FleetRequest'
          end
        end
      end
    end
  end
end
