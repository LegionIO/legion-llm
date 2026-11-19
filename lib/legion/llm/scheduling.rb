# frozen_string_literal: true

require 'legion/logging/helper'
module Legion
  module LLM
    module Scheduling
      extend Legion::Logging::Helper

      class << self
        # Returns true when off-peak scheduling is enabled in settings.
        def enabled?
          Legion::Settings[:llm][:scheduling][:enabled] == true
        end

        # Determines whether a request should be deferred to off-peak hours.
        #
        # @param intent  [Symbol, String] the request intent
        # @param urgency [Symbol]         :immediate bypasses deferral regardless of settings
        # @return [Boolean]
        def should_defer?(intent: :normal, urgency: :normal)
          return false unless enabled?
          return false if urgency.to_sym == :immediate

          result = eligible_for_deferral?(intent.to_sym) && peak_hours?
          log.debug("Scheduling defer decision intent=#{intent} urgency=#{urgency} defer=#{result}")
          result
        end

        # Returns true if the given UTC hour falls within the configured peak window.
        def peak_hours?(time = Time.now.utc)
          hour = time.is_a?(Time) ? time.hour : Time.now.utc.hour
          peak_range.cover?(hour)
        end

        # Returns the next off-peak time as a Time object (UTC).
        # Off-peak begins at the hour after the peak window ends.
        #
        # @return [Time] next off-peak start time
        def next_off_peak(time = Time.now.utc)
          now = time.is_a?(Time) ? time : Time.now.utc
          peak_end = peak_range.last
          max_defer = Legion::Settings[:llm][:scheduling][:max_defer_hours]

          next_time = if peak_hours?(now)
                        # During peak — next off-peak is at peak_end + 1
                        candidate = Time.utc(now.year, now.month, now.day, peak_end + 1, 0, 0)
                        candidate += 86_400 if candidate <= now
                        candidate
                      else
                        # Already off-peak — return now
                        now
                      end

          # Cap at max_defer_hours from now
          cap = now + (max_defer * 3600)
          [next_time, cap].min
        end

        # Returns a hash summarizing current scheduling state.
        def status
          {
            enabled:         enabled?,
            peak_hours:      peak_hours?,
            peak_range:      peak_range.to_s,
            next_off_peak:   peak_hours? ? next_off_peak.iso8601 : 'now',
            defer_intents:   defer_intents,
            max_defer_hours: Legion::Settings[:llm][:scheduling][:max_defer_hours]
          }
        end

        private

        def peak_range
          raw = Legion::Settings[:llm][:scheduling][:peak_hours_utc]
          raise ArgumentError, 'llm.scheduling.peak_hours_utc must be an hour range such as 14-22' unless raw.is_a?(String) && raw.match?(/\A\d{1,2}-\d{1,2}\z/)

          start_h, end_h = raw.split('-').map { |hour| Integer(hour, 10) }
          raise ArgumentError, 'llm.scheduling.peak_hours_utc must be an ordered range within 0-23' unless start_h.between?(0, 23) && end_h.between?(start_h, 23)

          (start_h..end_h)
        end

        def defer_intents
          Legion::Settings[:llm][:scheduling][:defer_intents].map(&:to_sym)
        end

        def eligible_for_deferral?(intent)
          defer_intents.include?(intent)
        end
      end
    end
  end
end
