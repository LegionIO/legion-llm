# frozen_string_literal: true

module Legion
  module LLM
    module Transport
      module Exchanges
        class Escalation < ::Legion::Transport::Exchange
          exchange_name 'llm.escalation'
          exchange_type :topic
        end
      end
    end
  end
end
