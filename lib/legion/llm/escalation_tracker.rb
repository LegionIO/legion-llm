# frozen_string_literal: true

require 'legion/logging/helper'
module Legion
  module LLM
    module EscalationTracker
      extend Legion::Logging::Helper

      MAX_HISTORY = 200

      class << self
        def record(from_model:, to_model:, reason:, tier_from: nil, tier_to: nil)
          entry = {
            from_model:  from_model.to_s,
            to_model:    to_model.to_s,
            reason:      reason.to_s,
            tier_from:   tier_from,
            tier_to:     tier_to,
            recorded_at: Time.now.utc
          }
          history << entry
          history.shift while history.size > MAX_HISTORY
          log.info(
            "[llm][escalation] recorded from_model=#{from_model} to_model=#{to_model} " \
            "reason=#{reason} tier_from=#{tier_from || 'none'} tier_to=#{tier_to || 'none'}"
          )
          entry
        end

        def history
          @history ||= []
        end

        def clear
          @history = []
          log.debug('[llm][escalation] history_cleared')
        end

        def summary
          entries = history.dup
          return empty_summary if entries.empty?

          {
            total_escalations: entries.size,
            by_reason:         count_by(entries, :reason),
            by_target_model:   count_by(entries, :to_model),
            by_source_model:   count_by(entries, :from_model),
            recent:            entries.last(5).reverse
          }
        end

        def escalation_rate(window_seconds: 3600)
          cutoff = Time.now.utc - window_seconds
          recent = history.count { |e| e[:recorded_at] >= cutoff }
          { count: recent, window_seconds: window_seconds }
        end

        private

        def count_by(entries, key)
          entries.group_by { |e| e[key] }.transform_values(&:size)
        end

        def empty_summary
          {
            total_escalations: 0,
            by_reason:         {},
            by_target_model:   {},
            by_source_model:   {},
            recent:            []
          }
        end
      end
    end
  end
end
