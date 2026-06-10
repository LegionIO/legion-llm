# frozen_string_literal: true

require 'legion/logging/helper'
require_relative 'logging'

module Legion
  module LLM
    module Inference
      module Steps
        module StickyPersist
          include Legion::Logging::Helper
          include Steps::Logging
          include Steps::StickyHelpers

          SENSITIVE_PARAM_NAMES = %w[
            api_key token secret password bearer_token
            access_token private_key secret_key auth_token credential
          ].freeze

          def step_sticky_persist
            return unless sticky_persist_ready?

            conv_id        = @request.conversation_id
            state          = Inference::Conversation.read_sticky_state(conv_id).dup
            runners        = (state[:sticky_runners] || {}).dup
            deferred_count = state[:deferred_tool_calls] || 0

            # Single Settings::Extensions snapshot for all lookups
            tool_snapshot = if Legion::Settings::Extensions.respond_to?(:tools)
                              Array(Legion::Settings::Extensions.tools)
                                .select { |t| t.is_a?(Hash) && t[:name] }
                                .to_h { |t| [t[:name], t] }
                            else
                              {}
                            end

            pending_snapshot = @pending_tool_history.dup # Concurrent::Array#dup is thread-safe
            completed        = pending_snapshot.select { |e| e[:result] && !e[:error] }
            log_step_debug(
              :sticky_persist,
              :state_loaded,
              runner_count:    runners.size,
              pending_count:   pending_snapshot.size,
              completed_count: completed.size,
              deferred_count:  deferred_count
            )

            executed_runner_keys = []
            deferred_call_count  = 0

            completed.each do |entry|
              tc = @injected_tool_map[entry[:tool_name]] || tool_snapshot[entry[:tool_name]]
              next unless tool_entry_deferred?(tc)

              key = entry[:runner_key] || tool_entry_runner_key(tc)
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
                runner_key = entry[:runner_key] || (tc ? tool_entry_runner_key(tc) : 'unknown')

                history << {
                  tool:   entry[:tool_name],
                  runner: runner_key,
                  turn:   @sticky_turn_snapshot,
                  args:   sanitize_args(truncate_args(normalize_history_args(entry[:args]))),
                  result: entry[:result].to_s[0, max_result_length],
                  error:  entry[:error] || false
                }
              end

              state[:tool_call_history] = history.last(max_history_entries)
            end

            Inference::Conversation.write_sticky_state(conv_id, state)
            log_step_debug(
              :sticky_persist,
              :state_written,
              runner_count:          runners.size,
              executed_runner_count: executed_runner_keys.size,
              deferred_call_count:   deferred_call_count,
              history_count:         state[:tool_call_history]&.size || 0
            )
          rescue StandardError => e
            @warnings << "sticky_persist error: #{e.message}"
            handle_exception(e, level: :warn, operation: 'llm.pipeline.step_sticky_persist')
          end

          private

          def sticky_persist_ready?
            unless @sticky_turn_snapshot
              log_step_debug(:sticky_persist, :skipped, reason: :no_turn_snapshot)
              return false
            end
            unless sticky_enabled?
              log_step_debug(:sticky_persist, :skipped, reason: :disabled)
              return false
            end
            unless @request.conversation_id
              log_step_debug(:sticky_persist, :skipped, reason: :no_conversation_id)
              return false
            end

            true
          end

          def tool_entry_deferred?(entry)
            return false unless entry

            if entry.is_a?(Hash)
              entry[:deferred] == true
            elsif entry.respond_to?(:deferred?)
              entry.deferred?
            else
              false
            end
          end

          def tool_entry_runner_key(entry)
            if entry.is_a?(Hash)
              "#{entry[:extension]}_#{entry[:runner]}"
            else
              "#{entry.extension}_#{entry.runner}"
            end
          end

          def normalize_history_args(args)
            case args
            when nil
              {}
            when Hash
              args
            when String
              return {} if args.strip.empty?

              parsed = Legion::JSON.parse(args)
              parsed.is_a?(Hash) ? parsed : {}
            else
              args.respond_to?(:to_h) ? args.to_h : {}
            end
          rescue StandardError => e
            handle_exception(e, level: :warn, handled: true, operation: 'llm.pipeline.step_sticky_persist.normalize_args')
            {}
          end

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
