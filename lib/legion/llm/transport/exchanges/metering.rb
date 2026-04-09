# frozen_string_literal: true

module Legion
  module LLM
    module Transport
      module Exchanges
        class Metering < ::Legion::Transport::Exchange
          def exchange_name
            'llm.metering'
          end

          def default_type
            'topic'
          end
        end
      end
    end
  end
end
