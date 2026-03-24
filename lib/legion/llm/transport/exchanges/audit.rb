# frozen_string_literal: true

module Legion
  module LLM
    module Transport
      module Exchanges
        class Audit < ::Legion::Transport::Exchange
          def exchange_name
            'llm.audit'
          end
        end
      end
    end
  end
end
