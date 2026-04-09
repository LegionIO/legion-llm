# frozen_string_literal: true

module Legion
  module LLM
    module Fleet
      class Exchange < ::Legion::Transport::Exchange
        def exchange_name = 'llm.request'
        def default_type  = 'topic'
      end
    end
  end
end
