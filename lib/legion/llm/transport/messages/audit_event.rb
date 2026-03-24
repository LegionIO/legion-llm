# frozen_string_literal: true

module Legion
  module LLM
    module Transport
      module Messages
        class AuditEvent < ::Legion::Transport::Message
          def exchange
            Legion::LLM::Transport::Exchanges::Audit
          end

          def routing_key
            'llm.audit.complete'
          end
        end
      end
    end
  end
end
