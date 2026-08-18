# frozen_string_literal: true

require 'legion/llm/inventory/capabilities'
require_relative 'router/resolution'
require 'legion/llm/inventory/discovery/system'
require 'legion/llm/inventory/discovery/memory_gate'
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

      PROVIDER_TIER = { bedrock: :cloud, anthropic: :frontier, openai: :frontier,
                        gemini: :cloud, azure: :cloud, ollama: :local, vllm: :fleet }.freeze
      PROVIDER_ORDER = %i[ollama vllm bedrock azure gemini anthropic openai].freeze
      TIER_EXTERNAL = Set[:cloud, :frontier].freeze
      TIER_RANK = { local: 0, direct: 1, fleet: 2, cloud: 3, frontier: 4 }.freeze
      CAPABILITY_ALIASES = {
        function_calling: :tools,
        functions:        :tools,
        tool:             :tools,
        tool_use:         :tools,
        stream:           :streaming,
        stream_chat:      :streaming
      }.freeze

      CANONICAL_EFFORT_LEVELS = %i[low moderate high reasoning].freeze
      EFFORT_ALIASES = { medium: :moderate }.freeze
      EFFORT_LEVELS = (CANONICAL_EFFORT_LEVELS + EFFORT_ALIASES.keys).freeze
      EFFORT_RANK = { low: 0, moderate: 1, high: 2, reasoning: 3 }.freeze
      OPERATIONS = %i[chat stream embed image structured_output].freeze
      OPERATION_ALIASES = { completion: :chat, stream_chat: :stream, embedding: :embed }.freeze
      DEFAULT_OPERATION = :chat
      DEFAULT_EFFORT = :moderate

      OLLAMA_MODEL_PATTERN = %r{[:/]}

      @auto_rules = []
      @auto_rules_populated = false
      @populate_auto_rules_warned = false

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

          build_selection(ranked: ranked, snapshot: snapshot)
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
        def build_selection(ranked:, snapshot:)
          evaluation = ranked.evaluation
          lane = evaluation.lane
          offering = evaluation.offering
          instance = evaluation.instance

          Legion::Extensions::Llm::Routing::Selection.new(
            inventory_generation: snapshot.generation,
            lane_id:              lane.lane_id,
            instance_key:         lane.instance_key,
            offering_id:          lane.offering_id,
            provider_family:      lane.provider_family,
            instance_id:          lane.instance_id,
            model:                lane.model,
            operation:            lane.operation,
            callable_handle:      lane.callable_handle,
            publisher_token_id:   instance.publisher_token_id,
            capability_evidence:  offering.capability_evidence,
            context_evidence:     offering.context_evidence,
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

        def auto_rules_populated?
          @auto_rules_populated == true
        end

        # DEPRECATED in v0.14.0; delete in v0.15.0.
        # See GitHub issues:
        #   #155 — remove this stub in v0.15.0 (blocked-by #154)
        #   #154 — drop call sites from 9 lex-llm-* gems
        def populate_auto_rules(_discovered_instances = nil, **)
          return if @populate_auto_rules_warned

          @populate_auto_rules_warned = true
          log.warn '[llm][router] populate_auto_rules is deprecated and is a no-op as of v0.14.0; ' \
                   'lex-llm-* gems should drop this call (RANKING v2 replaces auto-rules with lane weights)'
        end

        def reset!
          @auto_rules = []
          @auto_rules_populated = false
          @populate_auto_rules_warned = false
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
        # enterprise-privacy setting (or LEGION_ENTERPRISE_PRIVACY env override).
        def privacy_mode?
          if Legion::Settings.respond_to?(:enterprise_privacy?)
            Legion::Settings.enterprise_privacy?
          else
            ENV['LEGION_ENTERPRISE_PRIVACY'] == 'true'
          end
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
          aliases = Legion::LLM::Inventory::Capabilities::ALIASES
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
