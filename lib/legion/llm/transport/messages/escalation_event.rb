# frozen_string_literal: true

module Legion
  module LLM
    module Transport
      module Messages
        class EscalationEvent < ::Legion::Transport::Message
          routing_key 'llm.escalation.completed'
        end
      end
    end
  end
end
