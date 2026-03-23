# frozen_string_literal: true

require 'legion/llm/hooks/rag_guard'
require 'legion/llm/hooks/response_guard'
require 'legion/llm/hooks/metering'

module Legion
  module LLM
    module Hooks
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
          Legion::Logging.warn("LLM before_chat hook failed: #{e.message}") if defined?(Legion::Logging)
          nil
        end

        def run_after(response:, messages:, model:, **)
          @after_chat.each do |hook|
            result = hook.call(response: response, messages: messages, model: model, **)
            return result if result.is_a?(Hash) && result[:action] == :block
          end
          nil
        rescue StandardError => e
          Legion::Logging.warn("LLM after_chat hook failed: #{e.message}") if defined?(Legion::Logging)
          nil
        end

        def reset!
          @before_chat = []
          @after_chat = []
        end
      end
    end
  end
end
