# frozen_string_literal: true

require 'legion/logging/helper'

module Legion
  module LLM
    module Pipeline
      module Steps
        module StickyRunners
          include Legion::Logging::Helper
          include Steps::StickyHelpers

          def step_sticky_runners
            return unless sticky_enabled? && @request.conversation_id

            conv_id = @request.conversation_id

            # MUST be first — before any modification to @triggered_tools
            @sticky_turn_snapshot = ConversationStore.messages(conv_id)
                                                     .count { |m| (m[:role] || m['role']).to_s == 'user' }

            # MUST be second — captures trigger_match results before sticky re-injection
            @freshly_triggered_keys = @triggered_tools.map { |t| "#{t.extension}_#{t.runner}" }.uniq

            state          = ConversationStore.read_sticky_state(conv_id)
            runners        = state[:sticky_runners] || {}
            deferred_count = state[:deferred_tool_calls] || 0

            live_keys = runners.select do |_k, v|
              (v[:tier] == :triggered && @sticky_turn_snapshot < v[:expires_at_turn]) ||
                (v[:tier] == :executed && deferred_count < v[:expires_after_deferred_call])
            end.keys

            if defined?(::Legion::Tools::Registry)
              ::Legion::Tools::Registry.deferred_tools.each do |tool_class|
                key = "#{tool_class.extension}_#{tool_class.runner}"
                next unless live_keys.include?(key)
                next if tool_class.respond_to?(:sticky) && tool_class.sticky == false
                next if @triggered_tools.any? { |t| t.tool_name == tool_class.tool_name }

                @triggered_tools << tool_class
              end
            end

            @enrichments['tool:sticky_runners'] = {
              content:   "#{live_keys.size} runners re-injected via stickiness",
              data:      { runner_keys: live_keys },
              timestamp: Time.now
            }
            @timeline.record(
              category: :enrichment, key: 'tool:sticky_runners',
              direction: :inbound, detail: "#{live_keys.size} sticky runners",
              from: 'sticky_state', to: 'pipeline'
            )
          rescue StandardError => e
            @warnings << "sticky_runners error: #{e.message}"
            handle_exception(e, level: :warn, operation: 'llm.pipeline.step_sticky_runners')
          end
        end
      end
    end
  end
end
