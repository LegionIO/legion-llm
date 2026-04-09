# frozen_string_literal: true

module Legion
  module LLM
    module Metering
      class Exchange < ::Legion::Transport::Exchange
        def exchange_name = 'llm.metering'
        def default_type  = 'topic'
      end
    end
  end
end
