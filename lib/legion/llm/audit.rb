# frozen_string_literal: true

require 'legion/logging/helper'

module Legion
  module LLM
    module Audit
      extend Legion::Logging::Helper

      def self.load_transport
        return unless defined?(Legion::Transport::Message)

        require_relative 'transport/exchanges/audit'
        require_relative 'transport/messages/prompt_event'
        require_relative 'transport/messages/tool_event'
        require_relative 'transport/messages/skill_event'
      end

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

      def emit_skill(**event)
        if transport_connected? && defined?(Legion::LLM::Audit::SkillEvent)
          Legion::LLM::Audit::SkillEvent.new(**event).publish
          log.info('[llm][audit] published skill audit')
          :published
        else
          log.warn('[llm][audit] dropped skill audit: transport unavailable')
          :dropped
        end
      rescue StandardError => e
        handle_exception(e, level: :warn, operation: 'llm.audit.emit_skill')
        :dropped
      end

      def transport_connected?
        !!(defined?(Legion::Settings) &&
          Legion::Settings[:transport][:connected] == true)
      end
    end
  end
end
