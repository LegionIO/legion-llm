# frozen_string_literal: true

require 'legion/logging/helper'
module Legion
  module LLM
    module Hooks
      # Records a :given exchange event on the social graph whenever the LLM
      # responds to a caller that carries an identity. Runs as an after_chat hook.
      #
      # The hook is intentionally lightweight — it does not block the response
      # path and silently swallows all errors so a social-layer problem never
      # surfaces to the caller.
      module Reciprocity
        extend Legion::Logging::Helper
        module_function

        def install
          Legion::LLM::Hooks.after_chat do |caller: nil, **|
            record_reciprocity(caller: caller)
            nil
          end
        end

        def record_reciprocity(caller:)
          identity = caller&.dig(:requested_by, :identity)
          return unless identity

          runner = social_runner
          return unless runner

          runner.record_exchange(agent_id: identity, action: :communication, direction: :given)
        rescue StandardError => e
          handle_exception(e, level: :debug)
        end

        def social_runner
          return nil unless defined?(Legion::Extensions::Agentic::Social::Social::Client)

          Legion::Extensions::Agentic::Social::Social::Client.new
        rescue StandardError => e
          handle_exception(e, level: :debug)
          nil
        end
      end
    end
  end
end
