# frozen_string_literal: true

module Legion
  module LLM
    module Transport
      module Exchanges
        class Fleet < ::Legion::Transport::Exchange
          def exchange_name = 'llm.fleet'
          def default_type  = 'topic'
        end
      end
    end
  end
end
