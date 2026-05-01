# frozen_string_literal: true

require 'legion/logging/helper'

module Legion
  module LLM
    module Inference
      module Steps
        module StickyRunners
          include Legion::Logging::Helper
          include Steps::StickyHelpers

          def step_sticky_runners
            return unless sticky_enabled? && @request.conversation_id

            conv_id = @request.conversation_id

            # MUST be first — before any modification to @triggered_tools
            @sticky_turn_snapshot = Inference::Conversation.messages(conv_id)
                                                           .count { |m| (m[:role] || m['role']).to_s == 'user' }

            # MUST be second — captures trigger_match results before sticky re-injection
            @freshly_triggered_keys = @triggered_tools.map { |t| "#{t.extension}_#{t.runner}" }.uniq

            state          = Inference::Conversation.read_sticky_state(conv_id)
            runners        = state[:sticky_runners] || {}
            deferred_count = state[:deferred_tool_calls] || 0

            live_keys = runners.select do |_k, v|
              (v[:tier] == :triggered && @sticky_turn_snapshot < v[:expires_at_turn]) ||
                (v[:tier] == :executed && deferred_count < v[:expires_after_deferred_call])
            end.keys

            if Legion::Settings::Extensions.respond_to?(:filter_tools)
              Legion::Settings::Extensions.filter_tools(deferred: true).each do |entry|
                key = "#{entry[:extension]}_#{entry[:runner]}"
                next unless live_keys.include?(key)
                next if entry[:sticky] == false
                next if @triggered_tools.any? { |t| t.is_a?(Hash) ? t[:name] == entry[:name] : t.tool_name == entry[:name] }

                @triggered_tools << entry
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
