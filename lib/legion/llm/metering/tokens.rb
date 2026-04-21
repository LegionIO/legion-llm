# frozen_string_literal: true

require 'legion/logging/helper'
module Legion
  module LLM
    module Metering
      module Tokens
        extend Legion::Logging::Helper

        MUTEX = Mutex.new

        class << self
          # Records token usage from a completed LLM call.
          #
          # @param input_tokens  [Integer] number of input tokens consumed
          # @param output_tokens [Integer] number of output tokens produced
          # @return [Hash] the recorded entry
          def record(input_tokens:, output_tokens:)
            entry = {
              input_tokens:  input_tokens.to_i,
              output_tokens: output_tokens.to_i,
              recorded_at:   Time.now
            }

            MUTEX.synchronize { store << entry }
            log.debug "[LLM::TokenTracker] recorded #{input_tokens}+#{output_tokens} tokens (total: #{total_tokens})"
            entry
          end

          # Returns total tokens accumulated across all recorded calls.
          #
          # @return [Integer]
          def total_tokens
            MUTEX.synchronize { store.sum { |e| e[:input_tokens] + e[:output_tokens] } }
          end

          # Returns total input tokens accumulated.
          #
          # @return [Integer]
          def total_input_tokens
            MUTEX.synchronize { store.sum { |e| e[:input_tokens] } }
          end

          # Returns total output tokens accumulated.
          #
          # @return [Integer]
          def total_output_tokens
            MUTEX.synchronize { store.sum { |e| e[:output_tokens] } }
          end

          # Returns true when total_tokens >= session_max_tokens (and limit is configured).
          #
          # @return [Boolean]
          def session_exceeded?
            limit = session_max_tokens
            return false unless limit&.positive?

            total_tokens >= limit
          end

          # Returns true when total_tokens >= session_warn_tokens (and threshold is configured).
          #
          # @return [Boolean]
          def session_warning?
            threshold = session_warn_tokens
            return false unless threshold&.positive?

            total_tokens >= threshold
          end

          # Clears all recorded entries (for test isolation).
          def reset!
            MUTEX.synchronize { @store = [] }
          end

          # Returns a summary hash with totals and configured limits.
          #
          # @return [Hash]
          def summary
            max   = session_max_tokens
            warn  = session_warn_tokens
            total = total_tokens
            {
              total_tokens:        total,
              total_input_tokens:  total_input_tokens,
              total_output_tokens: total_output_tokens,
              session_max_tokens:  max,
              session_warn_tokens: warn,
              exceeded:            session_exceeded?,
              warning:             session_warning?,
              remaining:           max ? [max - total, 0].max : nil
            }
          end

          private

          def store
            @store ||= []
          end

          def session_max_tokens
            return nil unless defined?(Legion::Settings)

            Legion::Settings.dig(:llm, :budget, :session_max_tokens)
          rescue StandardError => e
            handle_exception(e, level: :debug)
            nil
          end

          def session_warn_tokens
            return nil unless defined?(Legion::Settings)

            Legion::Settings.dig(:llm, :budget, :session_warn_tokens)
          rescue StandardError => e
            handle_exception(e, level: :debug)
            nil
          end
        end
      end
    end
  end
end
