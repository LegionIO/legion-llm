# frozen_string_literal: true

require_relative 'scheduling'

module Legion
  module LLM
    # Simplified peak-hour interface delegating to Scheduling.
    # Preserved for backward compatibility.
    module OffPeak
      class << self
        def peak_hour?(time = Time.now.utc)
          Scheduling.peak_hours?(time)
        end

        def should_defer?(priority: :normal)
          return false if priority.to_sym == :urgent

          peak_hour?
        end

        def next_off_peak(time = Time.now.utc)
          Scheduling.next_off_peak(time)
        end
      end
    end
  end
end
