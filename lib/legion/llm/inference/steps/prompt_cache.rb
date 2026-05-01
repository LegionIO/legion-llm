# frozen_string_literal: true

require 'legion/logging/helper'

module Legion
  module LLM
    module Inference
      module Steps
        module PromptCache
          extend self
          extend Legion::Logging::Helper

          # Adds cache_control to the last system block when prompt caching is enabled
          # and the combined content exceeds the configured min_tokens threshold.
          #
          # @param system_blocks [Array<Hash>] array of system message hashes
          # @return [Array<Hash>] system blocks, possibly with cache_control on last entry
          def apply_cache_control(system_blocks)
            return system_blocks unless caching_enabled? && cache_system_prompt?
            return system_blocks if system_blocks.nil? || system_blocks.empty?

            total_chars = system_blocks.sum { |b| b[:content].to_s.length }
            min_chars   = prompt_caching_value(:min_tokens, 1024) * 4

            return system_blocks if total_chars < min_chars

            scope = prompt_caching_value(:scope, 'ephemeral')
            log.info("[llm][prompt_cache] cache_control scope=#{scope} total_chars=#{total_chars}")
            system_blocks[0..-2] + [system_blocks.last.merge(cache_control: { type: scope })]
          end

          # Sorts tool schemas deterministically by name so the cache key is stable
          # across calls with the same tool set in different order.
          #
          # @param tools [Array<Hash>] array of tool definition hashes with :name key
          # @return [Array<Hash>] tools sorted by name
          def sort_tools_deterministically(tools)
            return tools unless caching_enabled? && sort_tools?
            return tools if tools.nil? || tools.empty?

            log.debug("[llm][prompt_cache] sort_tools count=#{tools.size}")
            tools.sort_by { |t| t[:name].to_s }
          end

          # Marks the last stable (non-new) message with a cache breakpoint so the
          # provider can cache the conversation prefix up to that point.
          #
          # @param messages [Array<Hash>] ordered list of conversation messages
          # @return [Array<Hash>] messages, possibly with cache_control on the last stable one
          def apply_conversation_breakpoint(messages)
            return messages unless caching_enabled? && cache_conversation?
            return messages if messages.nil? || messages.size < 2

            scope   = prompt_caching_value(:scope, 'ephemeral')
            prior   = messages[0..-2]
            current = messages.last

            last_stable_idx = prior.rindex { |m| !m[:cache_control] }
            return messages unless last_stable_idx

            updated_prior = prior.dup
            updated_prior[last_stable_idx] = prior[last_stable_idx].merge(cache_control: { type: scope })
            log.info("[llm][prompt_cache] conversation_breakpoint scope=#{scope} index=#{last_stable_idx}")
            updated_prior + [current]
          end

          private

          def prompt_caching_settings
            Legion::LLM::Settings.value(:prompt_caching, default: {})
          rescue StandardError => e
            handle_exception(e, level: :warn, handled: true, operation: 'llm.pipeline.steps.prompt_cache.settings')
            {}
          end

          def prompt_caching_value(key, default = nil)
            Legion::LLM::Settings.config_value(prompt_caching_settings, key, default)
          end

          def caching_enabled?
            prompt_caching_value(:enabled, false)
          end

          def cache_system_prompt?
            prompt_caching_value(:cache_system_prompt, true)
          end

          def cache_conversation?
            prompt_caching_value(:cache_conversation, true)
          end

          def sort_tools?
            prompt_caching_value(:sort_tools, true)
          end
        end
      end
    end
  end
end
