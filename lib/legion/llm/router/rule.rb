# frozen_string_literal: true

require 'time'
require_relative 'resolution'

require 'legion/logging/helper'
module Legion
  module LLM
    module Router
      class Rule
        include Legion::Logging::Helper

        attr_reader :name, :conditions, :target, :priority, :constraint, :fallback, :cost_multiplier, :schedule, :note

        def self.from_hash(hash)
          h = hash.transform_keys(&:to_sym)
          new(
            name:            h[:name],
            conditions:      h[:when]  || {},
            target:          h[:then]  || {},
            priority:        h.fetch(:priority, 0),
            constraint:      h[:constraint],
            fallback:        h[:fallback].is_a?(Hash) ? h[:fallback].transform_keys(&:to_sym) : h[:fallback]&.to_sym,
            cost_multiplier: h.fetch(:cost_multiplier, 1.0),
            schedule:        h[:schedule],
            note:            h[:note]
          )
        end

        def initialize(name:, conditions:, target:, priority: 0, constraint: nil, fallback: nil,
                       cost_multiplier: 1.0, schedule: nil, note: nil)
          @name            = name
          @conditions      = conditions.transform_keys(&:to_sym)
          @target          = target.transform_keys(&:to_sym)
          @priority        = priority
          @constraint      = constraint
          @fallback        = fallback
          @cost_multiplier = cost_multiplier
          @schedule        = schedule
          @note            = note
        end

        def matches_intent?(intent)
          @conditions.all? do |key, value|
            unless intent.key?(key)
              log.debug("Rule '#{@name}' rejected: missing intent key=#{key}")
              return false
            end

            unless intent[key].to_s == value.to_s
              log.debug("Rule '#{@name}' rejected: intent #{key}=#{intent[key]} != #{value}")
              return false
            end

            true
          end
        end

        def to_resolution
          target_without_compress = @target.except(:compress_level)
          Resolution.new(
            **target_without_compress,
            rule:           @name,
            metadata:       { cost_multiplier: @cost_multiplier, fallback: @fallback }.compact,
            compress_level: @target.fetch(:compress_level, 0)
          )
        end

        def within_schedule?(now = Time.now)
          return true if @schedule.nil? || (@schedule.respond_to?(:empty?) && @schedule.empty?)

          sched = @schedule.transform_keys(&:to_s)
          now = localize(now, sched['timezone'])
          schedule_rejection(sched, now).nil?
        end

        private

        def schedule_rejection(sched, now)
          if sched['valid_from'] && now < Time.parse(sched['valid_from'])
            log.debug("Rule '#{@name}' rejected: before valid_from=#{sched['valid_from']}")
            return :valid_from
          end
          if sched['valid_until'] && now > Time.parse(sched['valid_until'])
            log.debug("Rule '#{@name}' rejected: after valid_until=#{sched['valid_until']}")
            return :valid_until
          end
          if sched['hours'] && !within_hours?(sched['hours'], now)
            log.debug("Rule '#{@name}' rejected: outside schedule hours=#{sched['hours']}")
            return :hours
          end
          if sched['days'] && !on_allowed_day?(sched['days'], now)
            log.debug("Rule '#{@name}' rejected: outside schedule days=#{sched['days']}")
            return :days
          end

          nil
        end

        def localize(time, timezone_name)
          return time unless timezone_name

          require 'tzinfo'
          TZInfo::Timezone.get(timezone_name).to_local(time)
        end

        def within_hours?(ranges, now)
          current = (now.hour * 60) + now.min
          ranges.any? do |range|
            start_str, end_str = range.split('-')
            start_min = time_str_to_minutes(start_str)
            end_min   = time_str_to_minutes(end_str)
            current.between?(start_min, end_min)
          end
        end

        def on_allowed_day?(days, now)
          today = now.strftime('%A').downcase
          days.map { |d| d.to_s.downcase }.include?(today)
        end

        def time_str_to_minutes(str)
          parts = str.split(':')
          (parts[0].to_i * 60) + parts[1].to_i
        end
      end
    end
  end
end
