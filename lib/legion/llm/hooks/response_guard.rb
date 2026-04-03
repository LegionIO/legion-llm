# frozen_string_literal: true

require 'legion/logging/helper'
module Legion
  module LLM
    module Hooks
      module ResponseGuard
        extend Legion::Logging::Helper

        GUARD_REGISTRY = {
          rag: RagGuard
        }.freeze

        class << self
          def guard_response(response:, context: nil, guards: [:rag], **)
            guard_results = {}

            guards.each do |guard_name|
              guard_mod = GUARD_REGISTRY[guard_name.to_sym]
              next unless guard_mod

              guard_results[guard_name] = dispatch_guard(guard_mod, guard_name,
                                                         response: response, context: context)
            end

            passed = guard_results.values.all? { |r| r[:faithful] != false }

            { passed: passed, guards: guard_results }
          rescue StandardError => e
            handle_exception(e, level: :warn)
            { passed: true, guards: {} }
          end

          private

          def dispatch_guard(guard_mod, guard_name, response:, context:)
            case guard_name.to_sym
            when :rag
              return { faithful: true, reason: :no_context } if context.nil?

              guard_mod.check_rag_faithfulness(response: response, context: context)
            else
              guard_mod.check(response: response, context: context)
            end
          end
        end
      end
    end
  end
end
