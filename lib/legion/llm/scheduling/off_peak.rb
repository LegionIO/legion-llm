# frozen_string_literal: true

require 'legion/logging/helper'
require_relative '../scheduling'

module Legion
  module LLM
    # Simplified peak-hour interface delegating to Scheduling.
    # Preserved for backward compatibility.
    module OffPeak
      extend Legion::Logging::Helper

      class << self
        def peak_hour?(time = Time.now.utc)
          Scheduling.peak_hours?(time)
        end

        def should_defer?(priority: :normal)
          return false if priority.to_sym == :urgent
          return false unless Scheduling.enabled?

          defer = peak_hour?
          log.debug("[llm][off_peak] should_defer priority=#{priority} defer=#{defer}")
          defer
        end

        def next_off_peak(time = Time.now.utc)
          next_window = Scheduling.next_off_peak(time)
          log.debug("[llm][off_peak] next_off_peak time=#{time.utc.iso8601} next=#{next_window&.utc&.iso8601}")
          next_window
        end
      end
    end
  end
end
