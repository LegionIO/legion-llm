# frozen_string_literal: true

require_relative 'capabilities'
require_relative 'router/resolution'
require_relative 'router/rule'
require_relative 'router/health_tracker'
require_relative 'router/availability'
require_relative 'router/candidates'
require_relative 'router/registry_lookup'
require_relative 'router/escalation/chain'
require_relative 'discovery/rule_generator'
require_relative 'discovery/system'
require_relative 'discovery/memory_gate'

require 'legion/logging/helper'
module Legion
  module LLM
    module Router
      extend Legion::Logging::Helper
      extend Candidates
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
        def infer_provider_for_model(model)
          return nil if model.nil? || model.to_s.empty?

          discovered = discover_provider_for_model(model)
          return discovered if discovered

          model_s = model.to_s
          return :bedrock if model_s.start_with?('us.')
          return :bedrock if model_s.match?(/\A(anthropic|meta|mistral|cohere|amazon|ai21)\./i)
          return :openai if model_s.match?(/\Agpt-|\Ao[134]-/)
          return :anthropic if model_s.start_with?('claude-')
          return :gemini if model_s.start_with?('gemini-')
          return :ollama if model_s.match?(OLLAMA_MODEL_PATTERN)

          nil
        end

        def discover_provider_for_model(model)
          return nil unless defined?(Discovery) && Discovery.respond_to?(:cached_discovered_models)

          model_s = model.to_s
          entry = Array(Discovery.cached_discovered_models).find do |m|
            dn = m[:model].to_s
            dn == model_s || dn.start_with?("#{model_s}:")
          end
          entry&.dig(:provider)
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
          handle_exception(e, level: :debug, handled: true, operation: 'router.inventory_default_model')
          nil
        end

        # Resolve an LLM routing intent to a tier/provider/model decision.
        #
        # Model, provider, and tier are treated as preference hints — they bias scoring
        # toward matching candidates but do not bypass rule evaluation. This allows the
        # router to apply policy (cost, privacy, health) and fall back to a better local
        # match when the hinted provider is unavailable.
        #
        # @param intent   [Hash, nil] routing intent (capability, privacy, etc.)
        # @param tier     [Symbol, nil] tier preference hint
        # @param model    [String, nil] model preference hint
        # @param provider [Symbol, nil] provider preference hint
        # @param estimated_tokens [Integer, nil] estimated total token count for context window filtering
        # @return [Resolution, nil]
        def resolve(intent: nil, tier: nil, model: nil, provider: nil, instance: nil, exclude: {}, estimated_tokens: nil)
          log.debug "[llm][router] action=resolve.enter intent=#{intent} tier=#{tier} model=#{model} provider=#{provider} instance=#{instance} estimated_tokens=#{estimated_tokens}"

          merged = merge_defaults(intent)
          rules = load_rules
          candidates = select_candidates(rules, merged, exclude: exclude, estimated_tokens: estimated_tokens)
          best = pick_best(candidates, intent: merged, hints: { tier: tier, provider: provider, model: model })
          resolution = best&.to_resolution

          # When a provider hint is explicitly passed but the best rule targets a DIFFERENT provider,
          # the hint has no matching rule to boost. If the hinted provider is registered (can actually
          # serve requests), fall through to explicit_resolution which honors the hint directly.
          # Without this, auto-rules for discoverable providers (vllm/ollama) always win over
          # non-discoverable providers (bedrock/anthropic) that have no auto-generated rules.
          if resolution && provider && resolution.provider.to_sym != provider.to_sym &&
             Call::Registry.registered?(provider.to_sym)
            log.info "[llm][router] action=resolve.hint_mismatch hinted_provider=#{provider} " \
                     "matched_provider=#{resolution.provider} falling_through_to_explicit"
            resolution = nil
          end

          if resolution
            log.info "[llm][router] action=resolve.matched tier=#{resolution.tier} provider=#{resolution.provider} " \
                     "model=#{resolution.model} rule=#{resolution.rule}"
          end

          # If no rules matched (or hint mismatch), fall back to explicit resolution from hints, then arbitrage.
          unless resolution
            trace_info = (@last_candidate_trace || {}).reject { |_, v| v.zero? }
            log.warn "[llm][router] action=resolve.no_rules_matched intent=#{merged} candidates_evaluated=#{rules.size} " \
                     "rejections=#{trace_info}"
            resolution = explicit_resolution(tier, provider, model, instance)
          end

          resolution || arbitrage_fallback(intent)
        end

        def resolve_chain(intent: nil, tier: nil, model: nil, provider: nil, instance: nil, max_escalations: nil,
                          exclude: {}, allow_default_fallback: true, estimated_tokens: nil)
          log.debug "[llm][router] action=resolve_chain.enter intent=#{intent} tier=#{tier} max_escalations=#{max_escalations} estimated_tokens=#{estimated_tokens}"
          max = max_escalations || escalation_max_attempts

          if routing_enabled? && intent
            chain_from_intent(intent, max, hints: { tier: tier, provider: provider, model: model, instance: instance },
                              exclude: exclude, allow_default_fallback: allow_default_fallback,
                              estimated_tokens: estimated_tokens)
          else
            chain_from_defaults(model, provider, max, hints: { tier: tier, instance: instance }, allow_default_fallback: allow_default_fallback)
          end
        end

        def health_tracker
          @health_tracker ||= build_health_tracker
        end

        def routing_enabled?
          Legion::Settings.dig(:llm, :routing, :enabled) == true && auto_rules_populated?
        end

        def auto_rules_populated?
          @auto_rules_populated == true
        end

        def populate_auto_rules(discovered_instances)
          raw = Discovery::RuleGenerator.generate(discovered_instances)
          @auto_rules = raw.map { |h| Rule.from_hash(h.transform_keys(&:to_sym)) }
          @auto_rules_populated = true
          log.info("[llm][router] auto_rules_populated count=#{@auto_rules.size}")
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
          handle_exception(e, level: :debug, handled: true, operation: 'router.fallback_model_offered')
          true
        end

        private

        def arbitrage_fallback(intent)
          return nil unless defined?(Arbitrage) && Arbitrage.enabled?

          effort = intent&.dig(:effort) || DEFAULT_EFFORT
          model = Arbitrage.cheapest_for(capability: effort)
          return nil unless model

          provider = infer_provider_for_model(model)
          return nil unless provider

          tier = PROVIDER_TIER.fetch(provider, :cloud)
          log.warn "[llm][router] action=arbitrage_fallback model=#{model} provider=#{provider} tier=#{tier}"
          Resolution.new(tier: tier, provider: provider, model: model, rule: 'arbitrage_fallback')
        end

        def normalize_intent(intent)
          normalized = symbolize_intent_keys(intent)

          normalized[:operation] = normalize_operation_value!(normalized[:operation] || DEFAULT_OPERATION)
          normalized[:effort] = normalize_effort_value!(normalized[:effort] || DEFAULT_EFFORT)
          required = normalize_capabilities(normalized.delete(:requires) || normalized[:required_capabilities])
          normalized[:required_capabilities] = required if required.any?
          normalized
        end

        def symbolize_intent_keys(intent)
          return {} unless intent.is_a?(Hash)

          intent.each_with_object({}) do |(key, value), memo|
            memo[key.respond_to?(:to_sym) ? key.to_sym : key] = value
          end
        end

        def normalize_enum_value(value)
          return nil unless value.respond_to?(:to_s)

          value.to_s.downcase.strip.to_sym
        end

        def normalize_effort(value)
          sym = normalize_enum_value(value)
          return nil unless sym

          canonical = EFFORT_ALIASES.fetch(sym, sym)
          CANONICAL_EFFORT_LEVELS.include?(canonical) ? canonical : nil
        end

        def normalize_operation(value)
          sym = normalize_enum_value(value)
          return nil unless sym

          canonical = OPERATION_ALIASES.fetch(sym, sym)
          OPERATIONS.include?(canonical) ? canonical : nil
        end

        def normalize_effort_value!(value)
          normalized = normalize_effort(value)
          return normalized if normalized

          raise ArgumentError, "unknown effort #{value.inspect}; expected #{CANONICAL_EFFORT_LEVELS.join(', ')}"
        end

        def normalize_operation_value!(value)
          normalized = normalize_operation(value)
          return normalized if normalized

          raise ArgumentError, "unknown operation #{value.inspect}; expected #{OPERATIONS.join(', ')}"
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

        def merge_defaults(intent)
          defaults = (Legion::Settings.dig(:llm, :routing, :default_intent) || {})
                     .transform_keys(&:to_sym)
                     .each_with_object({}) do |(k, v), memo|
                       memo[k] = v.respond_to?(:to_sym) ? v.to_sym : v
                     end

          raw_intent = intent&.transform_keys(&:to_sym) || {}
          merged = defaults.merge(raw_intent)
          normalize_intent(merged)
        end

        def load_rules
          manual = (Legion::Settings.dig(:llm, :routing, :rules) || []).map do |h|
            h = h.transform_keys(&:to_sym)
            h[:priority] = (h[:priority] || 0) + 1000
            Rule.from_hash(h)
          end
          (manual + (@auto_rules || [])).sort_by { |r| -r.priority }
        end

        def required_capabilities(intent)
          return [] unless intent.is_a?(Hash)

          normalized = intent.transform_keys { |key| key.respond_to?(:to_sym) ? key.to_sym : key }
          normalize_capabilities(normalized[:required_capabilities] || normalized[:requires])
        end

        def normalize_capabilities(capabilities)
          Array(capabilities).compact.each_with_object([]) do |capability, normalized|
            next unless capability.respond_to?(:to_s)

            capability_sym = capability.to_s.downcase.strip.to_sym
            next if capability_sym.to_s.empty?

            normalized << capability_sym
            alias_sym = CAPABILITY_ALIASES[capability_sym]
            normalized << alias_sym if alias_sym
          end.uniq
        end

        def discovery_enabled?
          Legion::Settings[:llm][:discovery][:enabled] != false
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

        def chain_from_defaults(model, provider, max, hints: {}, allow_default_fallback: true, # rubocop:disable Lint/UnusedMethodArgument
                                estimated_tokens: nil, required_capabilities: [])
          if provider || model || (allow_default_fallback && (Legion::Settings[:llm][:default_provider] || Legion::Settings[:llm][:default_model]))
            p = (provider || Legion::Settings[:llm][:default_provider])&.to_sym

            resolved_model = model
            if resolved_model
              model_natural = infer_provider_for_model(resolved_model)
              if model_natural && p && model_natural != p
                log.debug "[llm][router] action=chain_from_defaults.model_provider_mismatch model=#{resolved_model} " \
                          "natural_provider=#{model_natural} resolved_provider=#{p} swapping"
                resolved_model = nil
              end
            end
            registry_entry = registry_entry_for_provider(p)
            resolved_model ||= registry_default_model(registry_entry) ||
                               Legion::Settings[:llm][:default_model] || 'claude-sonnet-4-6'
            resolved_instance = registry_entry&.[](:instance)

            primary = Resolution.new(tier:     PROVIDER_TIER.fetch(p || :anthropic, :frontier),
                                     provider: p || :anthropic,
                                     model:    resolved_model,
                                     instance: resolved_instance)
            fallbacks = enabled_provider_chain.reject do |r|
              r.provider == primary.provider && r.instance == primary.instance
            end
            resolutions = ([primary] + fallbacks).uniq { |r| [r.provider, r.instance, r.model] }
            resolutions = filter_chain_resolutions(resolutions, estimated_tokens:      estimated_tokens,
                                                                required_capabilities: required_capabilities)
            return EscalationChain.new(resolutions: resolutions, max_attempts: max)
          end

          resolutions = enabled_provider_chain
          if resolutions.any?
            resolutions = filter_chain_resolutions(resolutions, estimated_tokens:      estimated_tokens,
                                                                required_capabilities: required_capabilities)
          end
          if resolutions.empty? && allow_default_fallback
            p = Legion::Settings[:llm][:default_provider]&.to_sym ||
                Legion::Settings[:llm][:routing][:last_resort_provider]
            last_resort = [Resolution.new(tier:     PROVIDER_TIER.fetch(p, :frontier),
                                          provider: p,
                                          model:    Legion::Settings[:llm][:default_model] ||
                                                    Legion::Settings[:llm][:routing][:last_resort_model])]
            resolutions = filter_chain_resolutions(last_resort, estimated_tokens:      estimated_tokens,
                                                                required_capabilities: required_capabilities)
          end
          EscalationChain.new(resolutions: resolutions, max_attempts: max)
        end

        def enabled_provider_chain
          instances = begin
            Call::Registry.all_instances
          rescue StandardError => e
            handle_exception(e, level: :debug, handled: true, operation: 'router.enabled_provider_chain')
            []
          end
          return [] if instances.empty?

          provider_index = PROVIDER_ORDER.each_with_index.to_h
          sorted_entries = instances.sort_by do |entry|
            tier = registry_tier(entry[:provider], entry[:metadata])
            [tier_rank.fetch(tier, 99), provider_index.fetch(entry[:provider], PROVIDER_ORDER.size)]
          end

          sorted_entries.filter_map do |entry|
            pname = entry[:provider]
            tier = registry_tier(pname, entry[:metadata])
            next unless tier_available?(tier)

            model = registry_default_model(entry) || inventory_default_model(pname, entry[:instance])
            next if model.nil? || model.to_s.empty?

            Resolution.new(
              tier: tier, provider: pname, model: model,
              instance: entry[:instance], rule: 'auto_chain'
            )
          end
        end

        # Honor an explicit provider hint as the chain PRIMARY even when no rule
        # targets that provider — mirroring Router.resolve's hint-mismatch
        # fallthrough so resolve and resolve_chain reach the same primary
        # (NxN G14 / redesign #95). The hinted provider must be registered (able
        # to serve); otherwise the normal scored chain stands.
        #
        # When the caller did not pin a specific instance, prepend EVERY registered
        # instance of the hinted provider, in registry order. This makes failover
        # exhaust the provider's own instances (e.g. a second Anthropic account)
        # before the chain ever crosses to a different provider — a creditless
        # instance fails over to a sibling instance, not silently to vLLM.
        def prepend_hinted_provider(resolutions, hints)
          provider = hints && hints[:provider]
          return resolutions unless provider

          provider_sym = provider.to_sym
          return resolutions unless Call::Registry.registered?(provider_sym)

          primaries = hinted_provider_resolutions(provider_sym, hints)
          return resolutions if primaries.empty?

          keys = primaries.map { |r| [r.provider, r.instance, r.model] }
          primaries + resolutions.reject { |r| keys.include?([r.provider, r.instance, r.model]) }
        end

        # Resolutions for the hinted provider: a pinned instance yields just that
        # one; otherwise one resolution per registered instance (multi-instance
        # failover within the provider).
        def hinted_provider_resolutions(provider_sym, hints)
          if hints[:instance]
            res = explicit_resolution(hints[:tier], provider_sym, hints[:model], hints[:instance])
            return res && res.provider == provider_sym ? [res] : []
          end

          instances = registered_instances_for(provider_sym)
          list = if instances.empty?
                   [explicit_resolution(hints[:tier], provider_sym, hints[:model], nil)]
                 else
                   instances.map { |inst| explicit_resolution(hints[:tier], provider_sym, hints[:model], inst) }
                 end
          list.compact.select { |r| r.provider == provider_sym }.uniq { |r| [r.provider, r.instance, r.model] }
        end

        def registered_instances_for(provider_sym)
          Call::Registry.all_instances
                        .select { |entry| entry[:provider] == provider_sym }
                        .filter_map { |entry| entry[:instance] }
                        .uniq
        rescue StandardError => e
          handle_exception(e, level: :debug, handled: true, operation: 'router.registered_instances_for')
          []
        end

        def chain_from_intent(intent, max, hints: {}, exclude: {}, allow_default_fallback: true, estimated_tokens: nil)
          merged     = intent ? merge_defaults(intent) : {}
          req_caps   = required_capabilities(merged)
          rules      = load_rules
          candidates = select_candidates(rules, merged, exclude: exclude, estimated_tokens: estimated_tokens)
          sorted = candidates.sort_by { |r| -effective_priority(r, intent: merged, hints: hints) }
          resolutions = sorted.map(&:to_resolution)
          resolutions = build_fallback_chain(sorted.first, sorted, resolutions) if sorted.first&.fallback
          resolutions = resolutions.uniq { |r| [r.provider, r.instance, r.model] }
          resolutions = prepend_hinted_provider(resolutions, hints)
          resolutions = filter_chain_resolutions(resolutions, estimated_tokens:      estimated_tokens,
                                                              required_capabilities: req_caps)
          resolutions = enabled_provider_chain if resolutions.empty?
          if resolutions.any?
            resolutions = filter_chain_resolutions(resolutions, estimated_tokens:      estimated_tokens,
                                                                required_capabilities: req_caps)
          end
          if resolutions.empty? && allow_default_fallback
            p = Legion::Settings[:llm][:default_provider]&.to_sym ||
                Legion::Settings[:llm][:routing][:last_resort_provider]
            last_resort = [Resolution.new(tier:     PROVIDER_TIER.fetch(p, :frontier),
                                          provider: p,
                                          model:    Legion::Settings[:llm][:default_model] ||
                                                    Legion::Settings[:llm][:routing][:last_resort_model])]
            resolutions = filter_chain_resolutions(last_resort, estimated_tokens:      estimated_tokens,
                                                                required_capabilities: req_caps)
          end
          EscalationChain.new(resolutions: resolutions, max_attempts: max)
        end

        def build_fallback_chain(primary_rule, candidates, default_chain)
          chain = [primary_rule.to_resolution]
          current = primary_rule

          while current.fallback
            fallback_target = current.fallback
            if fallback_target.is_a?(Hash)
              fb = fallback_target.transform_keys(&:to_sym)
              fb_tier     = fb[:tier]&.to_sym || :frontier
              fb_provider = fb[:provider]&.to_sym || default_provider_for_tier(fb_tier)
              fb_model    = fb[:model] || default_model_for_tier(fb_tier)
              chain << Resolution.new(tier: fb_tier, provider: fb_provider, model: fb_model)
              break
            else
              next_rule = candidates.find { |r| r.name == fallback_target.to_s }
              break unless next_rule

              chain << next_rule.to_resolution
              current = next_rule
            end
          end

          remaining = default_chain.reject { |r| chain.any? { |c| c.provider == r.provider && c.model == r.model } }
          chain + remaining
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
