# frozen_string_literal: true

require 'time'
require_relative 'resolution'

module Legion
  module LLM
    module Router
      class Rule
        attr_reader :name, :conditions, :target, :priority, :constraint, :fallback, :cost_multiplier, :schedule, :note

        def self.from_hash(hash)
          h = hash.transform_keys(&:to_sym)
          new(
            name:            h[:name],
            conditions:      h[:when]  || {},
            target:          h[:then]  || {},
            priority:        h.fetch(:priority, 0),
            constraint:      h[:constraint],
            fallback:        h[:fallback] ? h[:fallback].to_sym : nil,
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
            return false unless intent.key?(key)

            intent[key].to_s == value.to_s
          end
        end

        def to_resolution
          Resolution.new(
            **@target,
            rule:     @name,
            metadata: { cost_multiplier: @cost_multiplier, fallback: @fallback }.compact
          )
        end

        def within_schedule?(now = Time.now)
          return true if @schedule.nil? || (@schedule.respond_to?(:empty?) && @schedule.empty?)

          sched = @schedule.transform_keys(&:to_s)

          return false if sched['valid_from']  && now < Time.parse(sched['valid_from'])
          return false if sched['valid_until'] && now > Time.parse(sched['valid_until'])
          return false if sched['hours'] && !within_hours?(sched['hours'], now)
          return false if sched['days']  && !on_allowed_day?(sched['days'], now)

          true
        end

        private

        def within_hours?(ranges, now)
          current = now.hour * 60 + now.min
          ranges.any? do |range|
            start_str, end_str = range.split('-')
            start_min = time_str_to_minutes(start_str)
            end_min   = time_str_to_minutes(end_str)
            current >= start_min && current <= end_min
          end
        end

        def on_allowed_day?(days, now)
          today = now.strftime('%A').downcase
          days.map { |d| d.to_s.downcase }.include?(today)
        end

        def time_str_to_minutes(str)
          parts = str.split(':')
          parts[0].to_i * 60 + parts[1].to_i
        end
      end
    end
  end
end
