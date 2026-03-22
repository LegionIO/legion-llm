# frozen_string_literal: true

module Legion
  module LLM
    module OffPeak
      # Peak hours in UTC: 14:00-22:00 (9 AM - 5 PM CT)
      PEAK_HOURS = (14..22)

      class << self
        # Returns true if the given time falls within peak hours.
        #
        # @param time [Time] time to check (defaults to now)
        # @return [Boolean]
        def peak_hour?(time = Time.now.utc)
          PEAK_HOURS.cover?(time.hour)
        end

        # Returns true when a non-urgent request should be deferred to off-peak.
        #
        # @param priority [Symbol] :urgent bypasses deferral; :normal and :low defer during peak
        # @return [Boolean]
        def should_defer?(priority: :normal)
          return false if priority.to_sym == :urgent

          peak_hour?
        end

        # Returns the next off-peak Time (UTC).
        # If already off-peak, returns the current time.
        # Off-peak begins at the hour after the peak window ends (23:00 UTC).
        #
        # @param time [Time] reference time (defaults to now)
        # @return [Time]
        def next_off_peak(time = Time.now.utc)
          if time.hour < PEAK_HOURS.first || time.hour >= PEAK_HOURS.last
            time
          else
            Time.utc(time.year, time.month, time.day, PEAK_HOURS.last, 0, 0)
          end
        end
      end
    end
  end
end
