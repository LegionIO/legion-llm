# frozen_string_literal: true

require 'legion/logging/helper'

module Legion
  module LLM
    module Inference
      module Steps
        module Logging
          include Legion::Logging::Helper

          private

          def log_step_debug(step, action, **context)
            log_step(:debug, step, action, context)
          end

          def log_step_info(step, action, **context)
            log_step(:info, step, action, context)
          end

          def log_step(level, step, action, context)
            log.public_send(level, step_log_message(step, action, context))
          rescue StandardError => e
            return unless respond_to?(:handle_exception, true)

            handle_exception(e, level: :warn, handled: true,
                                operation: 'llm.pipeline.steps.logging', step: step, action: action)
          end

          def step_log_message(step, action, context)
            parts = ["[llm][steps][#{step}] action=#{action}"]
            step_log_base_context.merge(context).each do |key, value|
              safe_value = step_log_safe_value(value)
              parts << "#{key}=#{safe_value}" unless safe_value.nil?
            end
            parts.join(' ')
          end

          def step_log_base_context
            {
              request_id:      step_log_reader(@request, :id),
              conversation_id: step_log_reader(@request, :conversation_id)
            }.compact
          end

          def step_log_reader(object, method_name)
            return unless object.respond_to?(method_name)

            object.public_send(method_name)
          rescue StandardError
            nil
          end

          def step_log_safe_value(value)
            case value
            when nil
              nil
            when Symbol, Numeric, TrueClass, FalseClass
              value
            when Array
              "count=#{value.size}"
            when Hash
              "keys=#{value.keys.size}"
            else
              value.to_s.gsub(/\s+/, ' ')[0, 200]
            end
          end
        end
      end
    end
  end
end
