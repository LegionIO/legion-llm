# frozen_string_literal: true

module Legion
  module LLM
    module EscalationTracker
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
          log_debug("escalation: #{from_model} -> #{to_model} reason=#{reason}")
          entry
        end

        def history
          @history ||= []
        end

        def clear
          @history = []
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

        def log_debug(msg)
          Legion::Logging.debug("[EscalationTracker] #{msg}") if defined?(Legion::Logging)
        end
      end
    end
  end
end
