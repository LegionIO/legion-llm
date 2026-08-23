# frozen_string_literal: true

require 'legion/logging/helper'
require 'legion/settings/helper'

module Legion
  module LLM
    module Routing
      # Lane eligibility: a lane is eligible iff every applicable filter
      # passes. Each filter is a pure (lane, fact) -> pass/fail check —
      # stateless, individually RSpec-testable.
      module Filter
        include Legion::Logging::Helper
        include Legion::Settings::Helper

        # Type constraint: the lane type/modality the request asks for, or nil when unconstrained.
        def filter_type(**opts)
          type = opts[:type]
          type if type.is_a?(Symbol)
        end
        # Provider constraint: the provider the request asks for, or nil when unconstrained.
        def filter_provider(**opts)
          provider = opts[:provider]
          provider if provider.is_a?(Symbol)
        end
        # Instance constraint: the instance the request asks for, or nil when unconstrained.
        def filter_instance(**opts)
          instance = opts[:instance]
          instance if instance.is_a?(String)
        end

        # Model constraint: the trusted X-Legion-Model header wins over the
        # request-body model. The trusted model must also pass the
        # body-model-hint whitelist/blacklist: an empty whitelist allows all,
        # a nonempty whitelist restricts to its members, and the blacklist
        # always blocks. Returns the model String, or nil when nothing
        # qualifies. No existence check — that belongs to the inventory.
        def filter_model(**opts)
          model_hint = if opts[:legion_model_header].is_a?(String)
                         opts[:legion_trusted_model]
                       elsif opts[:body_model].is_a?(String)
                         opts[:body_model]
                       end

          return unless model_hint.is_a?(String)
          return if settings[:body_model_hint_whitelist].any? && !settings[:body_model_hint_whitelist].include?(model_hint)
          return if settings[:body_model_hint_blacklist].include?(model_hint)

          model_hint
        end

        # Tier constraint: the tier the request asks for, or nil when unconstrained.
        def filter_tier(**opts)
          tier = opts[:tier]
          tier if tier.is_a?(Symbol)
        end
        # Policy: model whitelist/blacklist (substring, case-insensitive); blacklist wins.
        def filter_policy(lane:, whitelist:, blacklist:)
          model_lc = lane.model.downcase
          return :denied if Array(blacklist).any? { |e| model_lc.include?(e.to_s.downcase) }

          wl = Array(whitelist)
          return :denied if wl.any? && wl.none? { |e| model_lc.include?(e.to_s.downcase) }

          :allowed
        end
        # Capability constraint: the capabilities the request requires, or nil when none.
        def filter_capability(**opts)
          caps = Array(opts[:capabilities]).compact
          caps.empty? ? nil : caps.freeze
        end
        # Context constraint: the required context size (tokens), or nil when unconstrained.
        def filter_context(**opts)
          context = opts[:context]
          context if context.is_a?(Integer)
        end
        # Embedding-dimension constraint: the requested dimensionality, or nil when unconstrained.
        def filter_embedding_dimensions(**opts)
          dims = opts[:embedding_dimensions]
          dims if dims.is_a?(Integer)
        end
        # Availability: the exact-instance availability state.
        def filter_availability(instance:)
          return :unknown if instance.nil?

          avail = instance.availability
          return :unknown if avail.nil?

          case avail.state
          when :available   then :available
          when :unavailable then :unavailable
          else                   :unknown
          end
        end
        # Fleet contract: the fleet execution contract (fleet tier only).
        def filter_fleet(lane:)
          return :not_applicable unless lane.tier == :fleet

          contract = lane.metadata[:fleet_execution_contract]
          if contract == 'exact_offering_v1'
            :supported
          elsif contract.nil? || contract.to_s.empty?
            :legacy
          else
            :unknown
          end
        end
        # Weight: the stored write-time weight; any zero component disables the lane.
        def filter_weight(lane:)
          inputs = lane.weight_inputs
          if inputs.nil? || inputs.values.any?(&:zero?)
            :disabled
          else
            :enabled
          end
        end
      end
    end
  end
end
