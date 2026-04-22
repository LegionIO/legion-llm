# frozen_string_literal: true

module Legion
  module LLM
    module Transport
      module Exchanges
        class Escalation < ::Legion::Transport::Exchange
          def exchange_name
            'llm.escalation'
          end

          def default_type
            'topic'
          end
        end
      end
    end
  end
end
