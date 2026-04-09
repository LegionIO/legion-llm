# frozen_string_literal: true

module Legion
  module LLM
    module Audit
      class Exchange < ::Legion::Transport::Exchange
        def exchange_name = 'llm.audit'
        def default_type  = 'topic'
      end
    end
  end
end
