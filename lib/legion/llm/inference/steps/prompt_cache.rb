# frozen_string_literal: true

require 'legion/logging/helper'

module Legion
  module LLM
    module Inference
      module Steps
        module PromptCache
          module_function

          extend Legion::Logging::Helper

          # Adds cache_control to the last system block when prompt caching is enabled
          # and the combined content exceeds the configured min_tokens threshold.
          #
          # @param system_blocks [Array<Hash>] array of system message hashes
          # @return [Array<Hash>] system blocks, possibly with cache_control on last entry
          def apply_cache_control(system_blocks)
            unless Legion::Settings[:llm][:prompt_caching][:enabled] && Legion::Settings[:llm][:prompt_caching][:cache_system_prompt]
              log.debug('[llm][prompt_cache] cache_control skipped=disabled')
              return system_blocks
            end
            if system_blocks.nil? || system_blocks.empty?
              log.debug('[llm][prompt_cache] cache_control skipped=empty_system')
              return system_blocks
            end

            total_chars = system_blocks.sum { |b| b[:content].to_s.length }
            min_chars   = Legion::Settings[:llm][:prompt_caching][:min_tokens] * 4

            if total_chars < min_chars
              log.debug("[llm][prompt_cache] cache_control skipped=below_threshold total_chars=#{total_chars} min_chars=#{min_chars}")
              return system_blocks
            end

            scope = Legion::Settings[:llm][:prompt_caching][:scope]
            log.info("[llm][prompt_cache] cache_control scope=#{scope} total_chars=#{total_chars}")
            system_blocks[0..-2] + [system_blocks.last.merge(cache_control: { type: scope })]
          end

          # Sorts tool schemas deterministically by name so the cache key is stable
          # across calls with the same tool set in different order.
          #
          # @param tools [Array<Hash>] array of tool definition hashes with :name key
          # @return [Array<Hash>] tools sorted by name
          def sort_tools_deterministically(tools)
            unless Legion::Settings[:llm][:prompt_caching][:enabled] && Legion::Settings[:llm][:prompt_caching][:sort_tools]
              log.debug('[llm][prompt_cache] sort_tools skipped=disabled')
              return tools
            end
            if tools.nil? || tools.empty?
              log.debug('[llm][prompt_cache] sort_tools skipped=empty_tools')
              return tools
            end

            log.debug("[llm][prompt_cache] sort_tools count=#{tools.size}")
            tools.sort_by { |t| t[:name].to_s }
          end

          # Marks the last stable (non-new) message with a cache breakpoint so the
          # provider can cache the conversation prefix up to that point.
          #
          # @param messages [Array<Hash>] ordered list of conversation messages
          # @return [Array<Hash>] messages, possibly with cache_control on the last stable one
          def apply_conversation_breakpoint(messages)
            unless Legion::Settings[:llm][:prompt_caching][:enabled] && Legion::Settings[:llm][:prompt_caching][:cache_conversation]
              log.debug('[llm][prompt_cache] conversation_breakpoint skipped=disabled')
              return messages
            end
            if messages.nil? || messages.size < 2
              log.debug("[llm][prompt_cache] conversation_breakpoint skipped=too_few_messages count=#{messages&.size || 0}")
              return messages
            end

            scope   = Legion::Settings[:llm][:prompt_caching][:scope]
            prior   = messages[0..-2]
            current = messages.last

            # Pipeline messages are Canonical::Message (cache_control is a
            # canonical member, kit T4); direct step-method specs may pass Hash
            # messages. Both shapes are read/written here.
            last_stable_idx = prior.rindex { |m| message_cache_control(m).nil? }
            unless last_stable_idx
              log.debug('[llm][prompt_cache] conversation_breakpoint skipped=no_stable_message')
              return messages
            end

            updated_prior = prior.dup
            updated_prior[last_stable_idx] = message_with_cache_control(prior[last_stable_idx], { type: scope })
            log.info("[llm][prompt_cache] conversation_breakpoint scope=#{scope} index=#{last_stable_idx}")
            updated_prior + [current]
          end

          def message_cache_control(message)
            return message[:cache_control] || message['cache_control'] if message.is_a?(Hash)

            message.respond_to?(:cache_control) ? message.cache_control : nil
          end
          private_class_method :message_cache_control

          def message_with_cache_control(message, cache_control)
            return message.merge(cache_control: cache_control) if message.is_a?(Hash)
            return message.with(cache_control: cache_control) if message.respond_to?(:with)

            message
          end
          private_class_method :message_with_cache_control
        end
      end
    end
  end
end
