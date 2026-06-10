# frozen_string_literal: true

require_relative 'router/resolution'
require_relative 'router/rule'
require_relative 'router/health_tracker'
require_relative 'router/escalation/chain'
require_relative 'discovery/rule_generator'
require_relative 'discovery/system'
require_relative 'discovery/memory_gate'

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
        def resolve(intent: nil, tier: nil, model: nil, provider: nil, instance: nil, exclude: {}, estimated_tokens: nil, **_opts)
          log.debug "[llm][router] action=resolve.enter intent=#{intent} tier=#{tier} model=#{model} provider=#{provider} instance=#{instance} estimated_tokens=#{estimated_tokens}"

          merged = merge_defaults(intent)
          rules = load_rules
          candidates = select_candidates(rules, merged, exclude: exclude, estimated_tokens: estimated_tokens)
          best = pick_best(candidates, hints: { tier: tier, provider: provider, model: model })
          resolution = best&.to_resolution

          if resolution
            log.info "[llm][router] action=resolve.matched tier=#{resolution.tier} provider=#{resolution.provider} " \
                     "model=#{resolution.model} rule=#{resolution.rule}"
          end

          # If no rules matched, fall back to explicit resolution from hints, then arbitrage.
          unless resolution
            log.warn "[llm][router] action=resolve.no_rules_matched intent=#{merged} candidates_evaluated=#{rules.size}"
            resolution = explicit_resolution(tier, provider, model, instance)
          end

          resolution || arbitrage_fallback(intent)
        end

        def resolve_chain(intent: nil, tier: nil, model: nil, provider: nil, max_escalations: nil,
                          exclude: {}, allow_default_fallback: true, estimated_tokens: nil, **_opts)
          log.debug "[llm][router] action=resolve_chain.enter intent=#{intent} tier=#{tier} max_escalations=#{max_escalations} estimated_tokens=#{estimated_tokens}"
          max = max_escalations || escalation_max_attempts

          if routing_enabled? && intent
            chain_from_intent(intent, max, hints: { tier: tier, provider: provider, model: model },
                              exclude: exclude, allow_default_fallback: allow_default_fallback,
                              estimated_tokens: estimated_tokens)
          else
            chain_from_defaults(model, provider, max, hints: { tier: tier }, allow_default_fallback: allow_default_fallback)
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

          resolved_model    = model || registry_default_model(registry_entry) || (tier && default_model_for_tier(tier))
          resolved_instance = registry_entry&.[](:instance) || instance
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

        private

        def arbitrage_fallback(intent)
          return nil unless defined?(Arbitrage) && Arbitrage.enabled?

          capability = intent&.dig(:capability) || :moderate
          model = Arbitrage.cheapest_for(capability: capability)
          return nil unless model

          provider = infer_provider_for_model(model)
          return nil unless provider

          tier = PROVIDER_TIER.fetch(provider, :cloud)
          log.warn "[llm][router] action=arbitrage_fallback model=#{model} provider=#{provider} tier=#{tier}"
          Resolution.new(tier: tier, provider: provider, model: model, rule: 'arbitrage_fallback')
        end

        def merge_defaults(intent)
          defaults = (Legion::Settings[:llm][:routing][:default_intent] || {})
                     .transform_keys(&:to_sym)
                     .transform_values { |v| v.respond_to?(:to_sym) ? v.to_sym : v }

          normalized_intent = intent&.transform_keys(&:to_sym)
                                    &.transform_values { |v| v.respond_to?(:to_sym) ? v.to_sym : v } || {}

          defaults.merge(normalized_intent)
        end

        def load_rules
          manual = (Legion::Settings[:llm][:routing][:rules] || []).map do |h|
            h = h.transform_keys(&:to_sym)
            h[:priority] = (h[:priority] || 0) + 1000
            Rule.from_hash(h)
          end
          (manual + (@auto_rules || [])).sort_by { |r| -r.priority }
        end

        def select_candidates(rules, intent, exclude: {}, estimated_tokens: nil, **_opts)
          log.debug "[llm][router] action=select_candidates total_rules=#{rules.size} estimated_tokens=#{estimated_tokens}"

          # 1. Collect constraints from constraint rules that match the intent
          constraints = rules
                        .select { |r| r.constraint && r.matches_intent?(intent) }
                        .map(&:constraint)

          # 2. Filter by intent match
          matched = rules.select { |r| r.matches_intent?(intent) }

          # 3. Filter by schedule
          scheduled = matched.select(&:within_schedule?)

          # 4. Reject rules that cannot satisfy required model capabilities
          capable = scheduled.select { |r| satisfies_required_capabilities?(r, intent) }

          # 5. Reject rules excluded by active constraints
          unconstrained = capable.reject { |r| excluded_by_constraint?(r, constraints) }

          # 5.5 Reject Ollama rules where model is not pulled or doesn't fit
          discovered = unconstrained.reject { |r| excluded_by_discovery?(r) }

          # 5.55 Reject local-tier rules where model exceeds available memory
          memory_checked = discovered.reject { |r| excluded_by_memory?(r) }

          # 5.56 Reject rules whose context window can't fit the estimated token count
          context_fitted = if estimated_tokens&.positive?
                             memory_checked.reject { |r| excluded_by_context_window?(r, estimated_tokens) }
                           else
                             memory_checked
                           end

          # 5.6 Reject rules matching caller-provided exclude list
          normalized_exclude = exclude.is_a?(Hash) ? exclude : {}
          not_excluded = if normalized_exclude.empty?
                           context_fitted
                         else
                           context_fitted.reject { |r| excluded_by_caller?(r, normalized_exclude) }
                         end

          # 5.7 Reject rules for models denied by health tracker
          not_denied = not_excluded.reject { |r| excluded_by_denial?(r) }

          # 6. Filter by tier availability
          final = not_denied.select { |r| tier_available?(r.target[:tier] || r.target['tier']) }

          log.debug "[llm][router] action=select_candidates.done candidates_remaining=#{final.size} started_with=#{rules.size}"

          final
        end

        # Reject rules whose model's context_length is too small for the estimated token count.
        # Uses a 90% threshold to leave room for output tokens, matching the executor's compaction threshold.
        def excluded_by_context_window?(rule, estimated_tokens)
          context_length = rule.target[:context_length] || rule.target['context_length']
          return false unless context_length&.to_i&.positive?

          threshold = (context_length.to_i * 0.90).to_i
          if estimated_tokens > threshold
            log.debug "[llm][router] action=excluded_by_context_window model=#{rule.target[:model]} " \
                      "context_length=#{context_length} estimated_tokens=#{estimated_tokens} threshold=#{threshold}"
            return true
          end
          false
        end

        def satisfies_required_capabilities?(rule, intent)
          required = required_capabilities(intent)
          return true if required.empty?

          rule_capabilities = normalize_capabilities(rule.target[:model_capabilities] || rule.target['model_capabilities'] ||
                                                     rule.target[:capabilities] || rule.target['capabilities'])
          return false if rule_capabilities.empty?

          required.all? { |capability| rule_capabilities.include?(capability) }
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

        def excluded_by_constraint?(rule, constraints)
          return false if constraints.empty?

          tier = (rule.target[:tier] || rule.target['tier'])&.to_sym

          constraints.any? do |c|
            case c.to_s
            when 'never_external'
              external_tier?(tier)
            when 'never_cloud'
              %i[cloud frontier].include?(tier)
            else
              false
            end
          end
        end

        def excluded_by_discovery?(rule)
          return false unless discovery_enabled?

          tier     = (rule.target[:tier] || rule.target['tier'])&.to_sym
          provider = (rule.target[:provider] || rule.target['provider'])&.to_sym
          model    = rule.target[:model] || rule.target['model']
          instance = rule.target[:instance] || rule.target['instance']

          return false unless tier == :local && model

          return true unless Discovery.model_available?(model, provider: provider, instance: instance)

          model_bytes = Discovery.model_size(model, provider: provider, instance: instance)
          available   = Discovery::System.available_memory_mb
          return false if model_bytes.nil? || available.nil?

          floor = Legion::Settings[:llm][:discovery][:memory_floor_mb]
          model_mb = model_bytes / 1024 / 1024
          model_mb > (available - floor)
        end

        def excluded_by_memory?(rule)
          return false unless discovery_enabled?

          tier = (rule.target[:tier] || rule.target['tier'])&.to_sym
          return false unless tier == :local

          model = rule.target[:model] || rule.target['model']
          provider = rule.target[:provider] || rule.target['provider']
          instance = rule.target[:instance] || rule.target['instance']
          !Discovery::MemoryGate.allow?(provider: provider, instance: instance, model: model)
        rescue StandardError => e
          handle_exception(e, level: :debug, handled: true, operation: 'router.excluded_by_memory')
          false
        end

        def discovery_enabled?
          Legion::Settings[:llm][:discovery][:enabled] != false
        end

        def excluded_by_denial?(rule)
          provider = (rule.target[:provider] || rule.target['provider'])&.to_sym
          model    = rule.target[:model] || rule.target['model']
          instance = rule.target[:instance] || rule.target['instance']
          return false unless provider && model

          health_tracker.model_denied?(provider: provider, model: model, instance: instance)
        end

        def excluded_by_caller?(rule, exclude)
          return false if exclude.nil? || exclude.empty?

          target   = rule.target || {}
          provider = (target[:provider] || target['provider'])&.to_sym
          model    = target[:model]    || target['model']
          tier     = (target[:tier]    || target['tier'])&.to_sym

          return true if exclude[:provider] && provider == exclude[:provider].to_sym
          return true if exclude[:model]    && model    == exclude[:model]
          return true if exclude[:tier]     && tier     == exclude[:tier].to_sym

          false
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

        def pick_best(candidates, hints: {})
          return nil if candidates.empty?

          candidates.max_by { |r| effective_priority(r, hints: hints) }
        end

        def effective_priority(rule, hints: {})
          provider = (rule.target[:provider] || rule.target['provider'])&.to_sym
          offering_id = rule.target[:offering_id] || rule.target['offering_id']
          cost_bonus = (1.0 - rule.cost_multiplier) * 10
          tier_bonus = tier_priority_bonus(rule)
          hint_bonus = hint_matching_bonus(rule, hints)
          rule.priority + health_tracker.adjustment(provider, offering_id: offering_id) + cost_bonus + tier_bonus + hint_bonus
        end

        # Score bonus when a rule's target matches caller-provided hints.
        # Each matching hint adds +50 to the priority, so a rule matching all three
        # hints gets +150. This makes hints strong preferences without overriding
        # rule priority, health, or cost considerations.
        def hint_matching_bonus(rule, hints)
          return 0 if hints.nil? || hints.empty?

          target = rule.target
          target_provider = (target[:provider] || target['provider'])&.to_sym
          target_tier     = (target[:tier]     || target['tier'])&.to_sym
          target_model    = target[:model] || target['model']

          bonus = 0
          bonus += 50 if hints[:provider] && target_provider == hints[:provider].to_sym
          bonus += 50 if hints[:tier]     && target_tier     == hints[:tier].to_sym
          bonus += 50 if hints[:model]    && target_model && target_model == hints[:model].to_s
          bonus
        end

        def tier_priority_bonus(rule)
          tier = (rule.target[:tier] || rule.target['tier'])&.to_sym
          return 0 unless tier

          index = tier_rank[tier]
          return 0 unless index

          (tier_priority.size - index) * 100
        end

        def build_health_tracker
          routing = Legion::Settings[:llm][:routing] || {}
          health = routing[:health] || {}
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

        # rubocop:disable Lint/UnusedMethodArgument
        def chain_from_defaults(model, provider, max, hints: {}, allow_default_fallback: true)
          if provider || model || (allow_default_fallback && (Legion::Settings[:llm][:default_provider] || Legion::Settings[:llm][:default_model]))
            p = (provider || Legion::Settings[:llm][:default_provider])&.to_sym

            # If the resolved provider differs from the model's natural provider, swap to the
            # provider's default model — sending "claude-sonnet-4-6" to vllm would fail.
            resolved_model = model
            if resolved_model
              model_natural = infer_provider_for_model(resolved_model)
              if model_natural && p && model_natural != p
                log.debug "[llm][router] action=chain_from_defaults.model_provider_mismatch model=#{resolved_model} " \
                          "natural_provider=#{model_natural} resolved_provider=#{p} swapping"
                resolved_model = nil
              end
            end
            resolved_model ||= registry_default_model(registry_entry_for_provider(p)) ||
                               Legion::Settings[:llm][:default_model] || 'claude-sonnet-4-6'

            primary = Resolution.new(tier:     PROVIDER_TIER.fetch(p || :anthropic, :frontier),
                                     provider: p || :anthropic,
                                     model:    resolved_model)
            # Append remaining registered providers as fallbacks (sorted by tier rank)
            fallbacks = enabled_provider_chain.reject { |r| r.provider == primary.provider }
            resolutions = ([primary] + fallbacks).uniq { |r| [r.provider, r.instance, r.model] }
            return EscalationChain.new(resolutions: resolutions, max_attempts: max)
          end

          resolutions = enabled_provider_chain
          if resolutions.empty? && allow_default_fallback
            p = Legion::Settings[:llm][:default_provider]&.to_sym || :anthropic
            resolutions = [Resolution.new(tier:     PROVIDER_TIER.fetch(p, :frontier),
                                          provider: p,
                                          model:    Legion::Settings[:llm][:default_model] || 'claude-sonnet-4-6')]
          end
          EscalationChain.new(resolutions: resolutions, max_attempts: max)
        end
        # rubocop:enable Lint/UnusedMethodArgument

        def enabled_provider_chain
          instances = begin
            Call::Registry.all_instances
          rescue StandardError => e
            handle_exception(e, level: :debug, handled: true, operation: 'router.enabled_provider_chain')
            []
          end
          return [] if instances.empty?

          # Deduplicate by provider (take the first instance per provider family)
          seen = {}
          instances.each do |entry|
            pname = entry[:provider]
            seen[pname] ||= entry
          end

          # Build resolutions ordered by configured tier priority, preserving provider preference inside a tier.
          provider_index = PROVIDER_ORDER.each_with_index.to_h
          sorted_entries = seen.values.sort_by do |entry|
            tier = registry_tier(entry[:provider], entry[:metadata])
            [tier_rank.fetch(tier, 99), provider_index.fetch(entry[:provider], PROVIDER_ORDER.size)]
          end

          sorted_entries.filter_map do |entry|
            pname = entry[:provider]
            entry = seen[pname]
            next unless entry

            tier = registry_tier(pname, entry[:metadata])
            next unless tier_available?(tier)

            model = registry_default_model(entry)
            next if model.nil? || model.to_s.empty?

            Resolution.new(tier: tier, provider: pname, model: model, rule: 'auto_chain')
          end
        end

        def chain_from_intent(intent, max, hints: {}, exclude: {}, allow_default_fallback: true, **_opts)
          merged     = intent ? merge_defaults(intent) : {}
          rules      = load_rules
          candidates = select_candidates(rules, merged, exclude: exclude)
          sorted     = candidates.sort_by { |r| -effective_priority(r, hints: hints) }
          resolutions = sorted.map(&:to_resolution)
          resolutions = build_fallback_chain(sorted.first, sorted, resolutions) if sorted.first&.fallback
          resolutions = resolutions.uniq { |r| [r.provider, r.model] }
          resolutions = enabled_provider_chain if resolutions.empty?
          if resolutions.empty? && allow_default_fallback
            p = Legion::Settings[:llm][:default_provider]&.to_sym || :anthropic
            resolutions = [Resolution.new(tier:     PROVIDER_TIER.fetch(p, :frontier),
                                          provider: p,
                                          model:    Legion::Settings[:llm][:default_model] || 'claude-sonnet-4-6')]
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

        def registry_tier_for_default_provider(provider)
          instances = begin
            Call::Registry.all_instances
          rescue StandardError => e
            log.debug "[llm][router] action=registry_tier_fallback error=#{e.class} message=#{e.message}"
            []
          end
          entry = instances.find { |i| i[:provider] == provider }
          return registry_tier(provider, entry[:metadata]) if entry

          PROVIDER_TIER.fetch(provider, :cloud)
        end

        # Determine tier for a provider: prefer registry metadata, fall back to PROVIDER_TIER constant.
        def registry_tier(provider, metadata = {})
          meta_tier = metadata[:tier] if metadata.is_a?(Hash)
          return meta_tier.to_sym if meta_tier

          PROVIDER_TIER.fetch(provider.to_sym, :cloud)
        end

        # Find first registered provider matching a given tier.
        def registry_provider_for_tier(tier)
          registry_entry_for_tier(tier)&.[](:provider)
        end

        # Find the first registered instance for a specific provider.
        # When +instance+ is given, prefers the entry whose :instance matches;
        # falls back to the first provider entry if no exact match is found.
        def registry_entry_for_provider(provider, instance: nil)
          instances = begin
            Call::Registry.all_instances
          rescue StandardError => e
            handle_exception(e, level: :warn, handled: true, operation: 'router.registry_entry_for_provider')
            []
          end
          provider_entries = instances.select { |entry| entry[:provider] == provider }
          return nil if provider_entries.empty?

          if instance
            provider_entries.find { |entry| entry[:instance] == instance } || provider_entries.first
          else
            provider_entries.first
          end
        end

        # Find a default model from registry for a given tier.
        # Tries adapter.offerings first, then metadata[:default_model].
        def registry_model_for_tier(tier)
          registry_default_model(registry_entry_for_tier(tier))
        end

        def registry_entry_for_tier(tier)
          instances = begin
            Call::Registry.all_instances
          rescue StandardError => e
            handle_exception(e, level: :debug, handled: true, operation: 'router.registry_entry_for_tier')
            []
          end

          PROVIDER_ORDER.each do |pname|
            entry = instances.find do |candidate|
              candidate[:provider] == pname && registry_tier(pname, candidate[:metadata]) == tier
            end
            return entry if entry
          end
          nil
        end

        # Extract a default model from a registry entry.
        # Checks metadata[:default_model], then adapter.offerings.
        def registry_default_model(entry)
          return nil unless entry

          metadata = entry[:metadata] || {}

          # Prefer explicit default_model in metadata
          dm = metadata[:default_model]
          return dm.to_s unless dm.nil? || dm.to_s.empty?

          # Try adapter offerings
          adapter = entry[:adapter]
          if adapter.respond_to?(:offerings)
            models = begin
              adapter.offerings
            rescue StandardError => e
              handle_exception(e, level: :debug, handled: true, operation: 'router.registry_default_model')
              []
            end
            first = models.first
            return first[:model] || first[:id] if first.is_a?(Hash) && (first[:model] || first[:id])
          end

          nil
        end

        def registry_resolution_metadata(entry)
          return {} unless entry

          metadata = entry[:metadata]
          metadata.is_a?(Hash) ? metadata.dup : {}
        end
      end
    end
  end
end
