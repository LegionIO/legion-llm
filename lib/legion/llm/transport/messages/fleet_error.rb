# frozen_string_literal: true

require 'legion/extensions/llm/transport/messages/fleet_error'

module Legion
  module LLM
    module Transport
      module Messages
        class FleetError
          def initialize(*, **)
            raise NotImplementedError,
                  'Use Legion::Extensions::Llm::Transport::Messages::FleetError'
          end
        end
      end
    end
  end
end
