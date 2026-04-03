# frozen_string_literal: true

require 'legion/logging/helper'
module Legion
  module LLM
    module Scheduling
      extend Legion::Logging::Helper
      # Default peak hours in UTC: 14:00-22:00 (9 AM - 5 PM CT)
      DEFAULT_PEAK_RANGE = (14..22)

      # Intents that are eligible for deferral during peak hours.
      DEFAULT_DEFER_INTENTS = %i[batch background maintenance].freeze

      class << self
        # Returns true when off-peak scheduling is enabled in settings.
        def enabled?
          settings.fetch(:enabled, false) == true
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
          max_defer = settings.fetch(:max_defer_hours, 8)

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
            max_defer_hours: settings.fetch(:max_defer_hours, 8)
          }
        end

        private

        def settings
          llm = Legion::Settings[:llm]
          return {} unless llm.is_a?(Hash)

          s = llm[:scheduling] || llm['scheduling'] || {}
          s.is_a?(Hash) ? s.transform_keys(&:to_sym) : {}
        rescue StandardError => e
          handle_exception(e, level: :warn)
          {}
        end

        def peak_range
          raw = settings[:peak_hours_utc]
          return DEFAULT_PEAK_RANGE unless raw.is_a?(String) && raw.include?('-')

          parts = raw.split('-')
          return DEFAULT_PEAK_RANGE unless parts.size == 2

          start_h = Integer(parts[0], 10)
          end_h   = Integer(parts[1], 10)
          (start_h..end_h)
        rescue ArgumentError => e
          handle_exception(e, level: :debug)
          DEFAULT_PEAK_RANGE
        end

        def defer_intents
          raw = settings[:defer_intents]
          return DEFAULT_DEFER_INTENTS unless raw.is_a?(Array)

          raw.map { |i| i.to_s.to_sym }
        end

        def eligible_for_deferral?(intent)
          defer_intents.include?(intent)
        end
      end
    end
  end
end
