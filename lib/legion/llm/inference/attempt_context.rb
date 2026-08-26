# frozen_string_literal: true

require 'legion/llm/errors'
require 'legion/extensions/llm/taxonomies'

module Legion
  module LLM
    module Inference
      # Immutable legion-owned execution object binding a Phase 1 Selection to
      # its same-generation LaneRecord (SSOT v3 §14.1). Phase 1 Selection does
      # not expose tier; AttemptContext resolves the lane from the exact snapshot
      # generation and re-validates cross-record identity before any dispatch.
      #
      # Any mismatch (generation drift, missing/mismatched lane/offering/instance,
      # publisher-token or callable-handle disagreement) raises the internal
      # Stale error before dispatch; RoutingSession converts it into a
      # stale_selection Rejection so the owner captures a fresh snapshot. The
      # consumed attempt target stays consumed across that transition.
      class AttemptContext
        include Legion::Logging::Helper

        # Internal stale-selection signal. Not a caller-facing error; RoutingSession
        # rescues it and returns a Phase 1 stale_selection Rejection.
        class Stale < StandardError; end

        attr_reader :selection, :lane, :attempt_target_key, :inventory_generation, :attempt_number

        def self.build(selection:, snapshot:, attempt_number:)
          new(selection: selection, snapshot: snapshot, attempt_number: attempt_number)
        end

        def initialize(selection:, snapshot:, attempt_number:)
          @selection = selection
          @attempt_number = Integer(attempt_number)
          @inventory_generation = selection.inventory_generation

          stale!('generation drift') unless snapshot.generation == selection.inventory_generation

          @lane = snapshot.lane(lane_id: selection.lane_id)
          stale!('lane absent in generation') if @lane.nil?

          instance = snapshot.instance(instance_key: selection.instance_key)
          stale!('instance absent in generation') if instance.nil?

          validate_lane_against_selection!
          validate_instance_against_selection!(instance)

          @attempt_target_key = selection.attempt_target_key
          freeze
        end

        # Fleet tier changes only the dispatch mechanism, never selection or
        # attempt identity.
        def fleet?
          @lane.tier == :fleet
        end

        private

        def validate_lane_against_selection!
          mismatches = []
          mismatches << 'provider_family' unless @lane.provider_family == @selection.provider_family
          mismatches << 'instance_id' unless @lane.instance_id == @selection.instance_id
          mismatches << 'lane_id' unless @lane.lane_id == @selection.lane_id
          mismatches << 'model' unless @lane.model == @selection.model
          # The selection freezes the REQUESTED fine operation (a request
          # property); the lane's operation member is the representative of its
          # coarse type. Compare the coarse lane types — the Selection record
          # already guarantees the fine op maps to the lane's type.
          mismatches << 'operation' unless
            Legion::Extensions::Llm::Taxonomies.lane_type_for(operation: @lane.operation) ==
            Legion::Extensions::Llm::Taxonomies.lane_type_for(operation: @selection.operation)
          mismatches << 'callable_handle' unless @lane.callable_handle.equal?(@selection.callable_handle)
          stale!("lane/selection mismatch: #{mismatches.join(',')}") unless mismatches.empty?
        end

        def validate_instance_against_selection!(instance)
          stale!('publisher token drift') unless instance.publisher_token_id == @selection.publisher_token_id
          # LaneRecord has no publisher-token field; validate the callable handle
          # against the activated instance record instead.
          return if instance.callable_handle.equal?(@selection.callable_handle)

          stale!('instance callable_handle mismatch')
        end

        def stale!(reason)
          raise Stale, "stale selection: #{reason} (lane=#{@selection.lane_id})"
        end
      end
    end
  end
end
