# frozen_string_literal: true

require 'legion/llm/inventory/capabilities'
require_relative 'router/resolution'
require_relative 'router/health_tracker'
require_relative 'router/availability'
require 'legion/llm/inventory/discovery/system'
require 'legion/llm/inventory/discovery/memory_gate'

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
        # Stateless lane selection — pure function of (Inventory snapshot, routing payload).
        # Returns one lane Hash or nil (caller raises NoLaneAvailable / EscalationExhausted).
        #
        # M1: when filters narrow to a single provider/instance, uses the indexed read
        # (Inventory.lanes_for) instead of full enumeration — same semantics, cheaper.
        # B-E / sonnet W2: lanes are Hashes; use { _1[:lane_weight] }, NOT &:lane_weight.
        def request_lane(
          type:,
          tiers: [], providers: [], instances: [], models: [],
          capabilities: [], thinking: :any, privacy: :normal,
          estimated_context: nil, tried_lanes: [],
          rng: default_rng,
          **
        )
          candidates = if providers.size == 1 && instances.size <= 1
                         Legion::LLM::Inventory.lanes_for(
                           provider: providers.first, instance: instances.first, type: type
                         )
                       else
                         Legion::LLM::Inventory.lanes
                       end

          passing = candidates.select do |lane|
            lane_passes_hard_filters?(
              lane: lane, type: type, tiers: tiers, providers: providers, instances: instances,
              models: models, capabilities: capabilities, thinking: thinking, privacy: privacy,
              estimated_context: estimated_context
            )
          end
          eligible = passing.reject { |lane| tried_lanes.include?(lane[:id]) || lane[:lane_weight].to_i <= 0 }

          return nil if eligible.empty?

          eligible
            .group_by { |lane| lane[:lane_weight] }
            .max_by { |weight, _| weight }
            .last
            .sample(random: rng)
        end

        def infer_provider_for_model(model)
          return nil if model.nil? || model.to_s.empty?

          model_s = model.to_s
          return :bedrock if model_s.start_with?('us.')
          return :bedrock if model_s.match?(/\A(anthropic|meta|mistral|cohere|amazon|ai21)\./i)
          return :openai if model_s.match?(/\Agpt-|\Ao[134]-/)
          return :anthropic if model_s.start_with?('claude-')
          return :gemini if model_s.start_with?('gemini-')
          return :ollama if model_s.match?(OLLAMA_MODEL_PATTERN)

          nil
        end

        # The provider's own default model from Inventory — the single source of
        # truth (already whitelist/blacklist-filtered and discovery-fed). Sourcing
        # a model here guarantees an explicit provider is paired only with a model
        # it actually offers: anthropic resolves to its own offered model, never a
        # stale registry default or a global default that belongs to a different
        # provider (the anthropic->qwen pairing class). Returns nil when Inventory
        # has no catalog for the provider (cold boot), so callers fall through to
        # their existing fallbacks.
        def inventory_default_model(provider, instance = nil)
          return nil unless provider && defined?(Inventory)

          candidates = Inventory.lanes_for(provider: provider.to_sym, type: :inference)
          return nil if candidates.nil? || candidates.empty?

          inst = (instance || :default).to_s
          offering = candidates.find { |o| (o[:instance_id] || o[:provider_instance]).to_s == inst } || candidates.first
          model = offering[:model] || offering[:canonical_model_alias]
          model&.to_s
        rescue StandardError => e
          handle_exception(e, level: :warn, handled: true, operation: 'router.inventory_default_model')
          nil
        end

        def health_tracker
          @health_tracker ||= build_health_tracker
        end

        def routing_enabled?
          false
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
          @health_tracker = nil
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

        private

        def lane_passes_hard_filters?(lane:, type:, tiers:, providers:, instances:, models:,
                                      capabilities:, thinking:, privacy:, estimated_context:, **)
          return false if lane[:type] != type
          return false if !tiers.empty?     && !tiers.map(&:to_sym).include?(lane[:tier])
          return false if !providers.empty? && !providers.map(&:to_sym).include?(lane[:provider_family])
          return false if !instances.empty? && !instances.map(&:to_sym).include?(lane[:instance_id])
          return false if !models.empty?    && !model_filter_match?(lane, models)

          # H-C / opus H3 / PR #152 I1: normalize capabilities on BOTH sides so :tools and
          # :function_calling/:tool_use are treated as aliases. Collapse to canonical-only
          # (aliases → canonical, drop the alias symbol) so the set-difference only compares
          # canonical forms: normalize([:function_calling]) = [:tools],
          # normalize([:tool_use]) = [:tools]. Bidirectional aliasing.
          requested = canonicalize_capabilities(capabilities)
          available = canonicalize_capabilities(Array(lane[:capabilities]))
          return false unless (requested - available).empty?

          return false if thinking == :require && !available.include?(:thinking)

          # Apply the same headroom the dispatch budget guard uses: a lane is only
          # eligible when estimated_context fits within context_window * headroom.
          # Keeps routing and RouteAttempts#enforce_final_context_budget! in
          # agreement so the router never picks a lane the pre-dispatch guard rejects.
          context_window = lane.dig(:limits, :context_window)
          if estimated_context && context_window
            usable = (context_window.to_i * context_headroom).to_i
            return false if usable < estimated_context
          end
          return false if privacy == :strict && %i[cloud frontier].include?(lane[:tier])

          true
        end

        def model_filter_match?(lane, requested_models)
          lane_models = [lane[:model], lane[:canonical_model_alias]].compact.map { |value| normalize_model_filter_value(value) }.uniq
          requested = Array(requested_models).map { |value| normalize_model_filter_value(value) }.uniq

          !!lane_models.intersect?(requested)
        end

        def normalize_model_filter_value(value)
          model = value.to_s
          model = model.sub(/\A(?:us|eu|ap)\./, '') if model.match?(/\A(?:us|eu|ap)\./)
          model
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

        def privacy_mode?
          if Legion::Settings.respond_to?(:enterprise_privacy?)
            Legion::Settings.enterprise_privacy?
          else
            ENV['LEGION_ENTERPRISE_PRIVACY'] == 'true'
          end
        end

        def external_tier?(tier)
          TIER_EXTERNAL.include?(tier)
        end

        def build_health_tracker
          health = Legion::Settings.dig(:llm, :routing, :health) || {}
          cb = health[:circuit_breaker] || {}

          HealthTracker.new(
            window_seconds:    health.fetch(:window_seconds, 300),
            failure_threshold: cb.fetch(:failure_threshold, 3),
            cooldown_seconds:  cb.fetch(:cooldown_seconds, 60)
          )
        end
      end
    end
  end
end
