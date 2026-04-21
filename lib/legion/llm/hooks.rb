# frozen_string_literal: true

require_relative 'hooks/rag_guard'
require_relative 'hooks/response_guard'
require_relative 'hooks/metering'
require_relative 'hooks/cost_tracking'
require_relative 'hooks/budget_guard'
require_relative 'hooks/reflection'
require_relative 'hooks/reciprocity'

require 'legion/logging/helper'
module Legion
  module LLM
    module Hooks
      extend Legion::Logging::Helper

      @before_chat = []
      @after_chat = []

      class << self
        def before_chat(&block)
          @before_chat << block
        end

        def after_chat(&block)
          @after_chat << block
        end

        def run_before(messages:, model:, **)
          @before_chat.each do |hook|
            result = hook.call(messages: messages, model: model, **)
            return result if result.is_a?(Hash) && result[:action] == :block
          end
          nil
        rescue StandardError => e
          handle_exception(e, level: :warn)
          nil
        end

        def run_after(response:, messages:, model:, **)
          @after_chat.each do |hook|
            result = hook.call(response: response, messages: messages, model: model, **)
            return result if result.is_a?(Hash) && result[:action] == :block
          end
          nil
        rescue StandardError => e
          handle_exception(e, level: :warn)
          nil
        end

        def install_defaults
          Metering.install
          CostTracking.install
          BudgetGuard.install if BudgetGuard.enforcing?
        end

        def reset!
          @before_chat = []
          @after_chat = []
        end
      end
    end
  end
end
