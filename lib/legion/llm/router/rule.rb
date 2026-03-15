# frozen_string_literal: true

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
      end
    end
  end
end
