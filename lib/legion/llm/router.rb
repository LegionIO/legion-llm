# frozen_string_literal: true

require 'legion/llm/inventory/capabilities'
require_relative 'router/resolution'
require_relative 'router/rule'
require_relative 'router/health_tracker'
require_relative 'router/availability'
require_relative 'router/registry_lookup'
require_relative 'router/escalation/chain'
require 'legion/llm/inventory/discovery/system'
require 'legion/llm/inventory/discovery/memory_gate'

require 'legion/logging/helper'
module Legion
  module LLM
    module Router
      extend Legion::Logging::Helper
      extend RegistryLookup

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

        def populate_auto_rules(_discovered_instances = nil)
          # Deprecated: RuleGenerator deleted in P4; full no-op stub lands in P5 per G8.
          # External lex-llm-* callers still reach this via respond_to? guards and must
          # not crash. @auto_rules_populated is intentionally left false so routing_enabled?
          # returns false, keeping the old rule-based path permanently inactive.
        end

        def reset!
          @health_tracker = nil
          @auto_rules = []
          @auto_rules_populated = false
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

        def explicit_resolution(tier, provider, model, instance = nil)
          # Track whether the caller explicitly specified a provider (before validation may clear it)
          provider_explicit = !provider.nil?

          # Validate provider hint against registry — if the hinted provider isn't registered,
          # fall through to tier-based or default resolution rather than committing to a dead end.
          if provider && !Call::Registry.registered?(provider.to_sym)
            log.debug "[llm][router] action=explicit_resolution.provider_not_registered provider=#{provider} falling_back"
            provider = nil
          end

          registry_entry = if provider
                             registry_entry_for_provider(provider.to_sym, instance: instance&.to_sym)
                           elsif tier
                             registry_entry_for_tier(tier)
                           end
          resolved_provider = if provider
                                provider.to_sym
                              else
                                registry_entry&.[](:provider) ||
                                  (tier && default_provider_for_tier(tier)) ||
                                  Legion::Settings[:llm][:default_provider]&.to_sym ||
                                  :anthropic
                              end

          # If the resolved provider differs from the model's natural provider, swap to the
          # provider's default model — sending "claude-sonnet-4-6" to vllm would fail.
          # Only swap when the provider was explicitly specified AND we can positively identify
          # the model's natural provider. If the provider was auto-resolved from tier/defaults,
          # trust the caller's model choice. Unknown model patterns (nil) are allowed through
          # since they may be custom/registry models.
          model_natural_provider = model && infer_provider_for_model(model)
          if provider_explicit && model && resolved_provider && model_natural_provider && model_natural_provider != resolved_provider
            log.debug "[llm][router] action=explicit_resolution.model_provider_mismatch model=#{model} " \
                      "natural_provider=#{model_natural_provider} resolved_provider=#{resolved_provider}"
            model = nil
          end

          resolved_instance = registry_entry&.[](:instance) || instance
          resolved_model    = model ||
                              inventory_default_model(resolved_provider, resolved_instance) ||
                              registry_default_model(registry_entry) ||
                              (tier && default_model_for_tier(tier))
          resolved_tier     = tier || PROVIDER_TIER.fetch(resolved_provider, :frontier)

          Resolution.new(
            tier:     resolved_tier,
            provider: resolved_provider,
            model:    resolved_model,
            instance: resolved_instance,
            rule:     'explicit',
            metadata: registry_resolution_metadata(registry_entry)
          )
        end

        def build_escalation_chain(provider:, model:, tier:, instance: nil, max_attempts: nil,
                                   estimated_tokens: nil, required_capabilities: [])
          primary = explicit_resolution(tier, provider, model, instance)
          fallbacks = build_fallback_resolutions(
            exclude_provider: provider,
            exclude_instance: instance,
            primary_tier:     tier
          )
          resolutions = ([primary] + fallbacks).compact.uniq { |r| [r.provider, r.instance, r.model] }
          resolutions = filter_chain_resolutions(resolutions, estimated_tokens:      estimated_tokens,
                                                              required_capabilities: required_capabilities)
          max = max_attempts || escalation_max_attempts
          EscalationChain.new(resolutions: resolutions, max_attempts: max)
        end

        def build_fallback_resolutions(exclude_provider: nil, exclude_instance: nil, primary_tier: nil)
          ranks = tier_rank
          primary_rank = primary_tier ? (ranks[primary_tier.to_sym] || 99) : 99

          candidates = Call::Registry.all_instances.filter_map do |entry|
            next if entry[:provider] == exclude_provider&.to_sym &&
                    (exclude_instance.nil? || entry[:instance] == (exclude_instance&.to_sym || :default))

            # Source from Inventory (SSOT) when the instance has no configured
            # registry default — e.g. a whitelist-restricted instance whose
            # policy-aware default resolved to nil. Without this, such a sibling
            # instance (a second account offering the same model) is dropped from
            # the escalation chain entirely.
            model = registry_default_model(entry) || inventory_default_model(entry[:provider], entry[:instance])
            next unless model
            # SSOT: the instance list comes from the registry, but the
            # (provider, model) fact must come from Inventory. Never manufacture a
            # fallback the live catalog doesn't offer — otherwise a configured-but-
            # unoffered default (e.g. bedrock + a model it doesn't serve) becomes a
            # dead candidate that availability rejects on every single request.
            next unless fallback_model_offered?(entry[:provider], model)

            entry_tier = PROVIDER_TIER.fetch(entry[:provider], :frontier)
            Resolution.new(
              tier:     entry_tier,
              provider: entry[:provider],
              instance: entry[:instance],
              model:    model,
              rule:     'escalation_fallback'
            )
          end

          candidates.sort_by do |r|
            r_rank = ranks[r.tier] || 99
            rank_diff = r_rank - primary_rank
            bucket = if rank_diff.zero?
                       0
                     elsif rank_diff.positive?
                       1
                     else
                       2
                     end
            [bucket, r_rank]
          end
        end

        # Whether the live catalog (Inventory SSOT) actually offers (provider, model).
        # Permissive on a nil/empty catalog (cold boot or lookup miss) so we never
        # over-prune before discovery populates — matching availability's cold-boot
        # stance. A NON-empty catalog that lacks the model is authoritative: drop it.
        def fallback_model_offered?(provider, model)
          offerings = Inventory.offerings(provider: provider)
          return true if offerings.nil? || offerings.empty?

          offerings.any? do |offering|
            offered = (offering[:model] || offering[:canonical_model_alias]).to_s
            offered == model.to_s || offered.start_with?("#{model}:")
          end
        rescue StandardError => e
          handle_exception(e, level: :warn, handled: true, operation: 'router.fallback_model_offered')
          true
        end

        private

        def lane_passes_hard_filters?(lane:, type:, tiers:, providers:, instances:, models:,
                                      capabilities:, thinking:, privacy:, estimated_context:, **)
          return false if lane[:type] != type
          return false if !tiers.empty?     && !tiers.map(&:to_sym).include?(lane[:tier])
          return false if !providers.empty? && !providers.map(&:to_sym).include?(lane[:provider_family])
          return false if !instances.empty? && !instances.map(&:to_sym).include?(lane[:instance_id])
          return false if !models.empty?    && !models.map(&:to_s).include?(lane[:model].to_s)

          # H-C / opus H3 / PR #152 I1: normalize capabilities on BOTH sides so :tools and
          # :function_calling are treated as aliases (gemini/openai/anthropic vocabularies).
          requested = Legion::LLM::Inventory::Capabilities.normalize(capabilities)
          available = Legion::LLM::Inventory::Capabilities.normalize(Array(lane[:capabilities]))
          return false unless (requested - available).empty?

          return false if thinking == :require && !available.include?(:thinking)

          context_window = lane.dig(:limits, :context_window)
          return false if estimated_context && context_window && context_window.to_i < estimated_context
          return false if privacy == :strict && %i[cloud frontier].include?(lane[:tier])

          true
        end

        def default_rng
          @default_rng ||= Random.new
        end

        def filter_chain_resolutions(resolutions, estimated_tokens:, required_capabilities:)
          filtered = Availability.filter_resolutions(
            resolutions,
            estimated_tokens:      estimated_tokens,
            required_capabilities: required_capabilities
          )
          return filtered unless filtered.empty? && resolutions.any?

          reasons = resolutions.filter_map do |resolution|
            Availability.rejection_reason(
              resolution,
              estimated_tokens:      estimated_tokens,
              required_capabilities: required_capabilities
            )
          end
          return filtered unless reasons.any? && reasons.all? { |reason| reason == :provider_instance_has_no_models }

          log.warn "[llm][router] action=availability.empty_catalog_preserve_chain candidates=#{resolutions.size}"
          resolutions
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

        def default_provider_for_tier(tier)
          sym = tier.to_sym

          # Check registry for the first registered provider in this tier
          registry_provider = registry_provider_for_tier(sym)
          return registry_provider if registry_provider

          # Fallback to static defaults when registry has no match
          case sym
          when :local, :direct, :fleet
            :ollama
          when :cloud
            default = Legion::Settings[:llm][:default_provider]
            default ? default.to_sym : :bedrock
          when :frontier
            :anthropic
          else
            :bedrock
          end
        end

        def default_model_for_tier(tier)
          sym = tier.to_sym

          # Try registry first: find a registered provider in this tier and ask for its model
          registry_model = registry_model_for_tier(sym)
          return registry_model if registry_model

          # Fallback to static defaults
          case sym
          when :local, :direct, :fleet
            default_settings_model_for_tier(sym) || 'llama3'
          when :cloud
            default_settings_model_for_tier(sym) || 'us.anthropic.claude-sonnet-4-6'
          when :frontier
            default_settings_model_for_tier(sym) || 'claude-sonnet-4-6'
          end
        end

        def escalation_max_attempts
          Legion::Settings.dig(:llm, :routing, :escalation, :max_attempts) || 3
        end

        def default_settings_model_for_tier(tier)
          model = Legion::Settings[:llm][:default_model]
          return nil if model.nil? || model.to_s.empty?

          provider = Legion::Settings[:llm][:default_provider]&.to_sym
          return nil unless provider

          provider_tier = registry_tier_for_default_provider(provider)
          return model if provider_tier == tier

          nil
        end
      end
    end
  end
end
