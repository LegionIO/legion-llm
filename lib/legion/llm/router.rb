# frozen_string_literal: true

require_relative 'router/resolution'
require 'legion/extensions/llm/capabilities'
require 'legion/extensions/llm/taxonomies'
require 'legion/extensions/llm/inventory/registry'

# SSOT v3 next_lane selector stack.
require 'legion/llm/router/settings_state'
require 'legion/llm/router/candidate_evaluator'
require 'legion/llm/router/ranker'
require 'legion/llm/router/rejection_diagnostics'

require 'legion/logging/helper'
module Legion
  module LLM
    module Router
      extend Legion::Logging::Helper

      # L1: the legacy routing vocabularies (PROVIDER_TIER, PROVIDER_ORDER,
      # CAPABILITY_ALIASES, the EFFORT_* family, OPERATIONS/OPERATION_ALIASES,
      # DEFAULT_OPERATION/DEFAULT_EFFORT, OLLAMA_MODEL_PATTERN) are gone —
      # second alias/rank tables duplicating the shared owners (lex-llm
      # Capabilities::ALIASES, Thinking::Config effort vocabulary,
      # Taxonomies.OPERATIONS) with zero live readers. The SSOT selector
      # stack reads the shared owners directly.
      TIER_EXTERNAL = Set[:cloud, :frontier].freeze
      TIER_RANK = { local: 0, direct: 1, fleet: 2, cloud: 3, frontier: 4 }.freeze

      # Lane-type label (the `type` part of the 5-tuple lane label used by the
      # ranker and stream-failover diagnostics). Consumer-owned display
      # vocabulary for this gem's log lines; the shared owner
      # (Legion::Extensions::Llm::Taxonomies.lane_type_for) is the single
      # mapping the identity composer and the selector stack consume.
      # Values stay within Taxonomies::TYPES.
      LANE_TYPE_BY_OPERATION = {
        chat: :inference, stream_chat: :inference, embed: :embedding,
        image: :image, transcribe: :audio, translate: :audio, speak: :audio,
        moderate: :inference, count_tokens: :inference
      }.freeze

      def self.lane_type_for(operation:)
        LANE_TYPE_BY_OPERATION.fetch(operation.to_sym)
      end

      # L1: the auto-rules era state (@auto_rules, @auto_rules_populated,
      # @populate_auto_rules_warned) and the populate_auto_rules no-op stub
      # are gone — RANKING v2 replaced auto-rules with lane weights, and the
      # lex-llm-* call sites that the deprecation timeline was waiting on are
      # gone with the 0.8.0 conformance.

      class << self
        # SSOT v3 §12: the single selection method. Pure function of
        # (routing_seed+requirements, exclusions, one snapshot generation, one
        # settings generation). Returns exactly one Phase 1 Selection or Rejection
        # — never nil, a lane hash, a model/provider string, a chain, or an array.
        def next_lane(requirements:, exclusions:, snapshot:)
          validate_exclusions!(exclusions)
          validate_snapshot!(snapshot)
          snapshot.generation # capture once (immutable snapshot)
          settings_snapshot = Legion::LLM::Router::SettingsState.current

          evaluation_set = Legion::LLM::Router::CandidateEvaluator.call(
            requirements: requirements, exclusions: exclusions,
            snapshot: snapshot, settings_snapshot: settings_snapshot
          )
          ranked = Legion::LLM::Router::Ranker.call(
            evaluation_set: evaluation_set, requirements: requirements, settings_snapshot: settings_snapshot
          )

          if ranked.nil? && hint_model_pin_active?(requirements)
            # v2 parity (v2 executor/routing.rb resolve_model_to_local_provider
            # model_discovery_miss: state[:model]=nil, auto_route=true): an
            # HONORED body-model hint that no candidate matches is not a caller
            # error — clear the hint pin and re-evaluate with normal weighted
            # selection (N x N: route to ANY qualifying lane). A trusted
            # X-Legion-Model pin never reaches this branch — explicit pins stay
            # hard. If the re-evaluation finds nothing, the normal no-lane
            # rejection stands (a real no-lane, not a hint problem).
            log.info("[llm][router] action=model_hint_miss model=#{requirements.model_pin} " \
                     'falling_back=weighted_selection')
            requirements = requirements.without_model_pin
            evaluation_set = Legion::LLM::Router::CandidateEvaluator.call(
              requirements: requirements, exclusions: exclusions,
              snapshot: snapshot, settings_snapshot: settings_snapshot
            )
            ranked = Legion::LLM::Router::Ranker.call(
              evaluation_set: evaluation_set, requirements: requirements, settings_snapshot: settings_snapshot
            )
          end

          if ranked.nil?
            return Legion::LLM::Router::RejectionDiagnostics.call(
              requirements: requirements, evaluation_set: evaluation_set, snapshot: snapshot
            )
          end

          build_selection(ranked: ranked, snapshot: snapshot, requirements: requirements)
        end

        def validate_exclusions!(exclusions)
          unless exclusions.is_a?(Array) &&
                 exclusions.all?(Legion::Extensions::Llm::Routing::Exclusion)
            raise ArgumentError, 'exclusions must be an Array of Phase 1 Routing::Exclusion records'
          end
        end
        private :validate_exclusions!

        def validate_snapshot!(snapshot)
          return if snapshot.is_a?(Legion::Extensions::Llm::Inventory::Snapshot)

          raise ArgumentError, 'snapshot must be a Phase 1 Inventory::Snapshot'
        end
        private :validate_snapshot!

        # Construct the Phase 1 Selection from the chosen RankedCandidate and its
        # evaluation's same-generation records. Never re-reads the registry.
        # The lane is the only inventory record (in the one bucket an offering
        # IS a lane) — its 5-tuple lane_id is the selection identity. The
        # selection freezes the REQUESTED fine operation (a request property
        # matched against the lane's coarse type by the evaluator), never the
        # lane's representative operation.
        def build_selection(ranked:, snapshot:, requirements:)
          evaluation = ranked.evaluation
          lane = evaluation.lane
          instance = evaluation.instance

          Legion::Extensions::Llm::Routing::Selection.new(
            inventory_generation: snapshot.generation,
            lane_id:              lane.lane_id,
            instance_key:         lane.instance_key,
            provider_family:      lane.provider_family,
            instance_id:          lane.instance_id,
            model:                lane.model,
            operation:            requirements.operation,
            callable_handle:      lane.callable_handle,
            publisher_token_id:   instance.publisher_token_id,
            capability_evidence:  lane.capability_evidence,
            context_evidence:     lane.context_evidence,
            weight_inputs:        ranked.weight_inputs,
            base_weight:          ranked.base_weight,
            preference_ppm:       ranked.preference_ppm,
            effective_weight:     ranked.effective_weight,
            rendezvous_score:     ranked.rendezvous_score
          )
        end
        private :build_selection

        # SSOT has no operator routing toggle (auto-rules era is gone): routing
        # is enabled whenever at least one instance has a complete publication
        # in the Registry.
        def routing_enabled?
          Legion::Extensions::Llm::Inventory::Registry.snapshot
                                                      .each_publication_status.any? { |ps| ps.state == :complete }
        end

        def tier_priority
          configured = Legion::Settings[:llm][:tier_order]
          configured = Legion::Settings[:llm][:routing][:tier_order] if configured.nil? || Array(configured).empty?
          configured = Legion::Settings[:llm][:routing][:tier_priority] if configured.nil? || Array(configured).empty?
          normalized = Array(configured).filter_map { |tier| tier.to_sym if tier.respond_to?(:to_sym) }
          normalized = TIER_RANK.keys if normalized.empty?
          (normalized + TIER_RANK.keys).uniq
        rescue StandardError => e
          handle_exception(e, level: :warn, handled: true, operation: 'router.tier_priority')
          TIER_RANK.keys
        end

        def tier_rank
          tier_priority.each_with_index.to_h
        end

        # Check whether a tier can be used right now.
        # :local    — always available
        # :direct   — always available (remote self-hosted instances)
        # :fleet    — available when Legion::Transport is loaded
        # :cloud    — available unless privacy mode
        # :frontier — available unless privacy mode
        def tier_available?(tier)
          sym = tier.to_sym
          if external_tier?(sym) && privacy_mode?
            log.debug "[llm][router] action=tier_available tier=#{sym} available=false reason=privacy_mode"
            return false
          end
          if sym == :fleet
            available = Legion.const_defined?('Transport', false)
            log.debug "[llm][router] action=tier_available tier=fleet available=#{available}"
            return available
          end

          true
        end

        # Public query for status endpoints (/api/llm/tiers). Reflects the
        # enterprise-privacy policy. L1: the consumer-side
        # ENV['LEGION_ENTERPRISE_PRIVACY'] fallback is gone — the env/setting
        # resolution lives in the shared owner (Legion::Settings
        # .enterprise_privacy?), which this consumes directly (Legion::Settings
        # is a hard dependency; no respond_to? guard).
        def privacy_mode?
          Legion::Settings.enterprise_privacy?
        end

        private

        # True only when the requirements' model pin is HINT-derived: an honored
        # body-model decision whose constraint is the active model pin. A trusted
        # X-Legion-Model pin supersedes the hint (disposition
        # :superseded_by_explicit_model, trusted.model wins in
        # RequestRequirements#resolve_model_pin) and never qualifies — explicit
        # pins stay hard and their miss is a caller error (400).
        def hint_model_pin_active?(requirements)
          decision = requirements.body_model_hint_decision
          decision.disposition == :honored && decision.model_constraint == requirements.model_pin
        end

        # Fraction of a lane's context_window the router treats as usable when
        # applying the estimated_context filter. Mirrors the dispatch-time budget
        # guard so routing and dispatch agree on what fits. Clamped to (0, 1].
        def context_headroom
          value = Legion::Settings.dig(:llm, :routing, :context_headroom)
          value = value.to_f
          value.positive? && value <= 1.0 ? value : 1.0
        rescue StandardError => e
          handle_exception(e, level: :warn, handled: true, operation: 'router.context_headroom')
          1.0
        end

        def default_rng
          @default_rng ||= Random.new
        end

        def canonicalize_capabilities(caps)
          aliases = Legion::Extensions::Llm::Capabilities::ALIASES
          Array(caps).compact.filter_map do |c|
            next unless c.respond_to?(:to_s)

            sym = c.to_s.downcase.strip.tr('-', '_').to_sym
            aliases.fetch(sym, sym)
          end.uniq
        end

        def external_tier?(tier)
          TIER_EXTERNAL.include?(tier)
        end
      end
    end
  end
end
