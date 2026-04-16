# frozen_string_literal: true

require 'legion/logging/helper'

module Legion
  module LLM
    module Pipeline
      module Steps
        module StickyPersist
          include Legion::Logging::Helper
          include Steps::StickyHelpers

          SENSITIVE_PARAM_NAMES = %w[
            api_key token secret password bearer_token
            access_token private_key secret_key auth_token credential
          ].freeze

          def step_sticky_persist # rubocop:disable Metrics/AbcSize,Metrics/MethodLength
            return unless @sticky_turn_snapshot
            return unless sticky_enabled? && @request.conversation_id

            conv_id        = @request.conversation_id
            state          = ConversationStore.read_sticky_state(conv_id).dup
            runners        = (state[:sticky_runners] || {}).dup
            deferred_count = state[:deferred_tool_calls] || 0

            # Single Registry snapshot — one mutex acquisition for all lookups
            tool_snapshot = if defined?(::Legion::Tools::Registry)
                              ::Legion::Tools::Registry.all_tools
                                                       .to_h { |t| [t.tool_name, t] }
                            else
                              {}
                            end

            pending_snapshot = @pending_tool_history.dup # Concurrent::Array#dup is thread-safe
            completed        = pending_snapshot.select { |e| e[:result] && !e[:error] }

            executed_runner_keys = []
            deferred_call_count  = 0

            completed.each do |entry|
              tc = @injected_tool_map[entry[:tool_name]] || tool_snapshot[entry[:tool_name]]
              next unless tc&.deferred?

              key = entry[:runner_key] || "#{tc.extension}_#{tc.runner}"
              executed_runner_keys << key
              deferred_call_count  += 1
            end

            executed_runner_keys.uniq!
            deferred_count              += deferred_call_count
            state[:deferred_tool_calls]  = deferred_count

            executed_runner_keys.each do |key|
              existing   = runners[key]
              new_expiry = deferred_count + execution_sticky_tool_calls
              runners[key] = {
                tier:                        :executed,
                expires_after_deferred_call: [existing&.dig(:expires_after_deferred_call) || 0, new_expiry].max
              }
            end

            (@freshly_triggered_keys - executed_runner_keys).each do |key|
              existing = runners[key]
              # Skip only if CURRENTLY live under execution tier (not expired).
              # An expired execution-sticky runner should be re-activated under trigger tier.
              if (existing&.dig(:tier) == :executed) && (deferred_count < (existing[:expires_after_deferred_call] || 0))
                next
                # Falls through when execution window is expired — apply trigger tier below
              end

              existing_expiry = runners.dig(key, :expires_at_turn) || 0
              # +1 accounts for the current user message not yet stored at snapshot time
              new_expiry      = @sticky_turn_snapshot + trigger_sticky_turns + 1
              runners[key]    = { tier: :triggered, expires_at_turn: [existing_expiry, new_expiry].max }
            end

            state[:sticky_runners] = runners

            if pending_snapshot.any?
              history = (state[:tool_call_history] || []).dup

              pending_snapshot.each do |entry|
                next unless entry[:result]

                tc         = @injected_tool_map[entry[:tool_name]] || tool_snapshot[entry[:tool_name]]
                runner_key = entry[:runner_key] || (tc ? "#{tc.extension}_#{tc.runner}" : 'unknown')

                history << {
                  tool:   entry[:tool_name],
                  runner: runner_key,
                  turn:   @sticky_turn_snapshot,
                  args:   sanitize_args(truncate_args(entry[:args] || {})),
                  result: entry[:result].to_s[0, max_result_length],
                  error:  entry[:error] || false
                }
              end

              state[:tool_call_history] = history.last(max_history_entries)
            end

            ConversationStore.write_sticky_state(conv_id, state)
          rescue StandardError => e
            @warnings << "sticky_persist error: #{e.message}"
            handle_exception(e, level: :warn, operation: 'llm.pipeline.step_sticky_persist')
          end

          private

          def sanitize_args(args)
            args.each_with_object({}) do |(k, v), h|
              h[k] = SENSITIVE_PARAM_NAMES.include?(k.to_s.downcase) ? '[REDACTED]' : v
            end
          end

          def truncate_args(args)
            args.each_with_object({}) do |(k, v), h|
              h[k] = v.to_s.length > max_args_length ? "#{v.to_s[0, max_args_length]}\u2026" : v
            end
          end
        end
      end
    end
  end
end
