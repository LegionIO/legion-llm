# frozen_string_literal: true

require 'legion/logging/helper'
require 'legion/extensions/llm/taxonomies'

module Legion
  module LLM
    # SSOT read facade over the lex-llm inventory registry. The registry
    # (Legion::Extensions::Llm::Inventory::Registry) is the single catalog:
    # one bucket of lanes keyed by the 5-tuple id
    # `tier:provider_family:instance_id:type:model` (composed only by
    # Inventory::Identity.compose_lane_id). This module holds no store of its
    # own — every read delegates to the registry snapshot.
    module Inventory
      extend Legion::Logging::Helper

      VALID_FILTER_KEYS = %i[provider_family instance_id model tier operation availability].freeze
      private_constant :VALID_FILTER_KEYS

      class << self
        # Returns the live registry snapshot (no args; generation-tagged).
        def snapshot
          Legion::Extensions::Llm::Inventory::Registry.snapshot
        end

        # Projects distinct, frozen, sorted provider-family Strings from the
        # supplied snapshot.  Filters: :provider_family, :instance_id, :tier,
        # :operation, :availability.  Unknown filter keys raise ArgumentError.
        def providers_from(snapshot:, filters: {}, **)
          validate_filter_keys!(filters)
          result = []
          snapshot.each_instance do |inst|
            next if filter_mismatch_instance?(inst, filters)

            family = inst.instance_key.provider_family.to_s
            result << family unless result.include?(family)
          end
          result.sort.freeze
        end

        # Projects frozen Array<Hash> of instance data from the supplied snapshot in
        # canonical InstanceKey order. Filters: :provider_family, :instance_id,
        # :availability. Unknown filter keys raise ArgumentError.
        def instances(snapshot:, filters: {}, **)
          validate_filter_keys!(filters)
          result = []
          snapshot.each_instance do |inst|
            next if filter_mismatch_instance?(inst, filters)

            result << project_instance(inst)
          end
          result.freeze
        end

        # Projects distinct, sorted, frozen Array<String> of model names from the
        # supplied snapshot's lanes. Filters: :provider_family, :instance_id,
        # :tier, :operation. Unknown filter keys raise ArgumentError.
        def models(snapshot:, filters: {}, **)
          validate_filter_keys!(filters)
          result = []
          snapshot.each_lane do |lane|
            next if filter_mismatch_lane?(lane, filters)

            model = lane.model
            result << model unless result.include?(model)
          end
          result.sort.freeze
        end

        private

        def validate_filter_keys!(filters)
          unknown = filters.keys.map(&:to_sym) - VALID_FILTER_KEYS
          raise ArgumentError, "unknown filter key(s): #{unknown.join(', ')}" unless unknown.empty?
        end

        # Returns true when the instance should be excluded by the supplied filters.
        def filter_mismatch_instance?(inst, filters)
          key = inst.instance_key
          fam = filters[:provider_family]
          iid = filters[:instance_id]
          avail = filters[:availability]
          return true if fam  && key.provider_family.to_s != fam.to_s
          return true if iid  && key.instance_id != iid.to_s
          return true if avail && inst.availability.state != avail.to_sym

          false
        end

        # Returns true when the lane should be excluded by the supplied filters.
        # The :operation filter matches the lane's coarse type (the 4th part of
        # the 5-tuple id) — the requested operation is a request property, not
        # a lane identity part.
        def filter_mismatch_lane?(lane, filters)
          fam  = filters[:provider_family]
          iid  = filters[:instance_id]
          mod  = filters[:model]
          tier = filters[:tier]
          op   = filters[:operation]
          return true if fam  && lane.provider_family.to_s != fam.to_s
          return true if iid  && lane.instance_id != iid.to_s
          return true if mod  && lane.model != mod.to_s
          return true if tier && lane.tier != tier.to_sym
          return true if op   && lane_type_for(lane) != lane_type_for_op(op)

          false
        end

        def lane_type_for(lane)
          Legion::Extensions::Llm::Taxonomies.lane_type_for(operation: lane.operation)
        end

        def lane_type_for_op(operation)
          Legion::Extensions::Llm::Taxonomies.lane_type_for(operation: operation)
        end

        # Projects a frozen Hash of safe, non-callable fields from an InstanceRecord.
        def project_instance(inst)
          key = inst.instance_key
          {
            provider_family:    key.provider_family,
            instance_id:        key.instance_id,
            availability:       inst.availability.state,
            publisher_id:       inst.publisher_id,
            publisher_token_id: inst.publisher_token_id,
            published_sequence: inst.published_sequence,
            published_at:       inst.published_at
          }.freeze
        end
      end
    end
  end
end
