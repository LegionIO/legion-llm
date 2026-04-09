# frozen_string_literal: true

require 'legion/logging/helper'

if defined?(Legion::Transport::Message)
  require_relative 'audit/exchange'
  require_relative 'audit/prompt_event'
  require_relative 'audit/tool_event'
end

module Legion
  module LLM
    module Audit
      extend Legion::Logging::Helper

      module_function

      def emit_prompt(event)
        if transport_connected? && defined?(Legion::LLM::Audit::PromptEvent)
          Legion::LLM::Audit::PromptEvent.new(**event).publish
          log.info('[llm][audit] published prompt audit')
          :published
        else
          log.warn('[llm][audit] dropped prompt audit: transport unavailable')
          :dropped
        end
      rescue StandardError => e
        handle_exception(e, level: :warn, operation: 'llm.audit.emit_prompt')
        :dropped
      end

      def emit_tools(event)
        if transport_connected? && defined?(Legion::LLM::Audit::ToolEvent)
          Legion::LLM::Audit::ToolEvent.new(**event).publish
          log.info('[llm][audit] published tool audit')
          :published
        else
          log.warn('[llm][audit] dropped tool audit: transport unavailable')
          :dropped
        end
      rescue StandardError => e
        handle_exception(e, level: :warn, operation: 'llm.audit.emit_tools')
        :dropped
      end

      def transport_connected?
        !!(defined?(Legion::Transport) &&
          Legion::Transport.respond_to?(:connected?) &&
          Legion::Transport.connected?)
      end
    end
  end
end
